import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

// Regression tests for the inspector reporting "Unblocks 0" for a bead that
// unblocks six.
//
// The count was fetched in a `.task`, so it read 0 until the async round-trip
// resolved — permanently in a static render, and as a visible flash in the live
// app. The plan and triage payloads already carry unblocks lists, so those
// populate a cache the view reads synchronously.

@MainActor
@Test("Unblocks is known synchronously right after load")
func unblocksKnownWithoutAwaiting() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    // The bug: this returned nil/0 until an async fetch completed.
    let known = store.knownUnblocks("vbx-3")
    #expect(known != nil, "unblocks must be known without a further round-trip")
    #expect(known?.count == 6, "vbx-3 unblocks six beads, got \(known?.count ?? -1)")

    await store.close()
}

@MainActor
@Test("Unblocks is distinct from blocks and excludes still-blocked dependents")
func unblocksExcludesStillBlocked() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let known = try? #require(store.knownUnblocks("vbx-3"))
    guard let known else { return }

    // vbx-3 blocks 7 beads but unblocks only 6: vbx-6 also waits on vbx-12,
    // so closing vbx-3 alone would not free it. Conflating the two counts is
    // exactly the kind of error this guards.
    #expect(store.metrics.blocks("vbx-3") == 7)
    #expect(known.count == 6)
    #expect(!known.contains("vbx-6"), "vbx-6 is still blocked by vbx-12")

    await store.close()
}

@MainActor
@Test("An unknown bead reports nil rather than an empty list")
func unknownBeadIsNilNotZero() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    // nil and [] must stay distinguishable: the view renders "—" for unknown
    // and "0" for genuinely-nothing, and showing 0 for unknown was the bug.
    #expect(store.knownUnblocks("no-such-bead") == nil)

    await store.close()
}

@MainActor
@Test("The async path agrees with the cache and caches its own result")
func asyncPathMatchesCache() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let cached = store.knownUnblocks("vbx-3")
    let fetched = await store.unblocks("vbx-3")
    #expect(Set(fetched ?? []) == Set(cached ?? []), "cache and engine disagree")

    // A bead outside the plan and triage falls through to the engine, and the
    // result is remembered so the view stops flashing on reselection.
    let closed = "vbx-1"
    #expect(store.knownUnblocks(closed) == nil)
    _ = await store.unblocks(closed)
    #expect(store.knownUnblocks(closed) != nil, "engine result was not cached")

    await store.close()
}

@MainActor
@Test("The cache is rebuilt on reload rather than going stale")
func cacheRebuildsOnReload() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)
    let before = store.knownUnblocks("vbx-3")?.count

    await store.reload(force: true)

    #expect(store.knownUnblocks("vbx-3")?.count == before)
    await store.close()
}
