import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Copies the demo fixture somewhere writable so a test can mutate it.
private func makeScratchWorkspace() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo/.beads/issues.jsonl")

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-watch-\(UUID().uuidString)")
    let beads = dir.appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: source, to: beads.appendingPathComponent("issues.jsonl"))
    return dir
}

@Test("The watcher fires on a real file change and debounces a burst")
func watcherFires() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let log = WatchLog()
    let watcher = FileWatchService()
    watcher.debounce = 0.15
    watcher.onSignalForTesting = { log.signal(at: $0) }

    watcher.start(watching: file.path) { log.fire() }
    #expect(watcher.isWatching)
    defer { watcher.stop() }

    // Let FSEvents settle before writing, or the stream can miss the first event.
    try await Task.sleep(for: .milliseconds(400))

    let original = try String(contentsOf: file, encoding: .utf8)
    for i in 0..<4 {
        try (original + "\n// touch \(i)\n").write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(20))
    }

    // Wait for the notification rather than for a fixed time: a loaded run can
    // take seconds to deliver it (vbx-7a2).
    let deadline = ContinuousClock.now + .seconds(20)
    while log.snapshot.fires == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    // Give any extra, wrongly undebounced notifications time to show.
    try await Task.sleep(for: .milliseconds(500))

    // The bound is taken from the gaps the debounce actually saw, not from the
    // 20 ms the test asked for. Under load those sleeps overshoot the window,
    // and then each write *should* fire on its own — asserting `fires <= 3`
    // regardless is what made this flaky. A notification can only run when the
    // next signal arrived at least a window later, so there is at most one per
    // such gap, plus one for the last signal. With no wide gap that is exactly
    // one, which is the burst collapsing. The collapse itself is pinned on a
    // virtual clock in DebouncerTests.
    let (signals, fires) = log.snapshot
    let window = UInt64(watcher.debounce * 1_000_000_000)
    let wideGaps = zip(signals, signals.dropFirst()).filter { $1 - $0 >= window }.count
    #expect(fires >= 1, "watcher never fired for a real write")
    #expect(!signals.isEmpty, "watcher fired without a signal")
    #expect(
        fires <= wideGaps + 1,
        "debounce failed to collapse a burst: fired \(fires)× for \(signals.count) signals with \(wideGaps) gap(s) ≥ the window"
    )
}

@Test("Stopping the watcher silences it")
func watcherStops() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let counter = Counter()
    let watcher = FileWatchService()
    watcher.debounce = 0.1
    watcher.start(watching: file.path) { counter.increment() }
    try await Task.sleep(for: .milliseconds(300))

    watcher.stop()
    #expect(!watcher.isWatching)

    let after = counter.value
    try "changed".write(to: file, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(500))

    #expect(counter.value == after, "watcher fired after stop()")
}

@MainActor
@Test("Reload is hash gated: unchanged content does no work")
func storeReloadIsGated() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProjectStore()
    await store.open(path: dir.path)
    #expect(store.isLoaded)
    #expect(store.issues.count == 18)

    // No content change: reload must report that it did nothing.
    let didChange = await store.reload()
    #expect(!didChange)
    #expect(store.info?.changed == false)

    // A real change must be picked up.
    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let original = try String(contentsOf: file, encoding: .utf8)
    let added = original + #"{"id":"vbx-99","title":"Added later","status":"open","issue_type":"task","priority":2}"# + "\n"
    try added.write(to: file, atomically: true, encoding: .utf8)

    let didChangeNow = await store.reload()
    #expect(didChangeNow)
    #expect(store.issues.count == 19)
    #expect(store.issuesByID["vbx-99"] != nil)

    await store.close()
}

@MainActor
@Test("Opening a workspace starts watching, closing stops it")
func storeManagesWatchLifecycle() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProjectStore()
    #expect(!store.isWatching)

    await store.open(path: dir.path)
    #expect(store.isWatching)

    await store.close()
    #expect(!store.isWatching)
}

/// Minimal thread-safe counter; the watcher callback arrives on its own queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}


/// What the watcher saw, under one lock so a snapshot is consistent: signal
/// times (uptime ns) and the number of notifications.
private final class WatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [UInt64] = []
    private var fires = 0

    func signal(at time: DispatchTime) {
        lock.lock()
        signals.append(time.uptimeNanoseconds)
        lock.unlock()
    }

    func fire() {
        lock.lock()
        fires += 1
        lock.unlock()
    }

    var snapshot: (signals: [UInt64], fires: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (signals, fires)
    }
}
