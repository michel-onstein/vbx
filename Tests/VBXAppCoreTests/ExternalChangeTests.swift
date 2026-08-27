import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// A change made to the workspace by something other than vbx.
///
/// The two halves of this were already tested and both passed: the watcher
/// fires on a real write, and `reload()` picks up a real change. What nothing
/// covered was the join — open a workspace, write to it from outside, and wait.
/// That is the path a `br` run in a terminal takes, and it is the one that was
/// broken. See vbx-d9p.
private func scratchWorkspace() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo/.beads/issues.jsonl")

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-external-\(UUID().uuidString)")
    let beads = dir.appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: source, to: beads.appendingPathComponent("issues.jsonl"))
    return dir
}

/// Waits for `condition`, re-applying `poke` as it goes. Returns whether it held.
///
/// A fixed sleep would either be flaky or slow: the path under test crosses
/// FSEvents' own latency, a debounce, and a hop to the main actor, and the
/// whole suite runs in parallel — 5 s was enough alone and not enough under
/// load.
///
/// `poke` rewrites the same content, so the wait does not hinge on the one
/// write landing inside the window where the stream has settled. It changes
/// nothing about what is being asserted: a watch aimed at another workspace
/// never sees any of these writes, however many there are. Whether the *first*
/// event is delivered is `WatchTests`' question, not this file's.
@MainActor
private func eventually(
    timeout: TimeInterval = 20, poke: (() -> Void)? = nil, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var lastPoke = Date()
    while Date() < deadline {
        if condition() { return true }
        if let poke, Date().timeIntervalSince(lastPoke) > 2 {
            poke()
            lastPoke = Date()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor
@Test("A bead added outside vbx reaches an open workspace")
func externalAdditionReachesTheStore() async throws {
    let dir = try scratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: dir.path)
    #expect(store.isLoaded)
    #expect(store.isWatching, "precondition: opening a workspace starts the watch")
    let before = store.issues.count

    // FSEvents needs a moment after the stream starts before it reports
    // reliably; the existing watcher test settles the same way.
    try await Task.sleep(for: .milliseconds(400))

    // Written the way `br` writes: a whole-file replace, which lands as an
    // atomic rename rather than an in-place write.
    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let original = try String(contentsOf: file, encoding: .utf8)
    let added = original
        + #"{"id":"vbx-ext","title":"Added by br","status":"open","issue_type":"task","priority":2}"#
        + "\n"
    let write: () -> Void = { _ = try? added.write(to: file, atomically: true, encoding: .utf8) }
    write()

    let arrived = await eventually(poke: write) { store.issuesByID["vbx-ext"] != nil }
    #expect(arrived, "an external write never reached the store (still \(store.issues.count) beads)")
    #expect(store.issues.count == before + 1)

    await store.close()
}


@MainActor
@Test("A second workspace is watched, not the first one still")
func openingAnotherWorkspaceMovesTheWatch() async throws {
    let first = try scratchWorkspace()
    let second = try scratchWorkspace()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: first.path)
    #expect(store.isWatching)

    // The second open is the whole point: `startWatching()` returned early
    // while a watch was already running, so the stream stayed aimed at the
    // workspace just left. Everything about the new one looked right — it was
    // loaded, listed and marked as watching — and nothing written to it ever
    // arrived. Opening a demo workspace and then a real one is enough to hit
    // it, which is most of the ways anyone gets here.
    await store.open(path: second.path)
    #expect(store.isLoaded)
    #expect(store.isWatching)
    let before = store.issues.count

    try await Task.sleep(for: .milliseconds(400))

    let file = second.appendingPathComponent(".beads/issues.jsonl")
    let original = try String(contentsOf: file, encoding: .utf8)
    let added = original
        + #"{"id":"vbx-second","title":"Added to the second","status":"open","issue_type":"task","priority":2}"#
        + "\n"
    let write: () -> Void = { _ = try? added.write(to: file, atomically: true, encoding: .utf8) }
    write()

    let arrived = await eventually(poke: write) { store.issuesByID["vbx-second"] != nil }
    #expect(arrived, "a write to the open workspace never arrived — the watch is on the old one")
    #expect(store.issues.count == before + 1)

    await store.close()
}


/// A scratch workspace that is inside a git repository.
private func scratchRepoWorkspace() throws -> URL {
    let dir = try scratchWorkspace()
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["init", "-q", dir.path]
    git.standardOutput = FileHandle.nullDevice
    git.standardError = FileHandle.nullDevice
    try git.run()
    git.waitUntilExit()
    return dir
}

@MainActor
@Test("Leaving a repository for a workspace in none stops the git watch")
func gitWatchDoesNotOutliveItsRepository() async throws {
    let inRepo = try scratchRepoWorkspace()
    let bare = try scratchWorkspace()
    defer {
        try? FileManager.default.removeItem(at: inRepo)
        try? FileManager.default.removeItem(at: bare)
    }

    let store = ProjectStore()
    store.skipPhase2 = true

    await store.open(path: inRepo.path)
    #expect(store.isWatchingGit, "a workspace in a repository is watched for commits")

    // The dirty mark is drawn from git. Left running, the old repository's
    // watch would go on recomputing this workspace's dirty state against a
    // repository it is not in.
    await store.open(path: bare.path)
    #expect(!store.isWatchingGit, "the previous repository is still being watched")

    await store.close()
}
