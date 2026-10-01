import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

// `Fixtures/readiness` holds the readiness and blocking cases bv 0.25 changed,
// none of which the demo fixture reaches — which is how numbers moved under the
// engine bump while every test stayed green. Each bead's description says what
// it is there for. The Go suite (readiness_fixture_test.go) and
// parity-check.py run over the same beads.

private typealias Bead = VBXCore.Issue

private var readinessPath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/readiness")
        .path
}

/// What bv 0.25.2 reports as ready over the fixture. rdy-5's deferral is in
/// 2099 and rdy-6's has passed, so the set does not depend on the clock.
private let bvReady: Set<String> = [
    "rdy-1", "rdy-6", "rdy-11", "rdy-12", "rdy-13", "rdy-15", "rdy-19", "rdy-20", "rdy-21",
]

@MainActor
@Test("Every readiness-fixture record decodes, custom status and tombstone included")
func readinessFixtureDecodesEveryRecord() async {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: readinessPath)

    // Decoding never drops a record: a dropped bead changes every metric.
    #expect(store.issues.count == 21)
    let byID = store.issuesByID
    #expect(byID["rdy-2"]?.status == .unknown("triage"))
    #expect(byID["rdy-3"]?.status == .blocked)
    #expect(byID["rdy-4"]?.status == .deferred)
    #expect(byID["rdy-10"]?.status == .tombstone)

    await store.close()
}

@MainActor
@Test("waits-for and conditional-blocks block; parent-child does not")
func readinessFixtureEdgeTypes() async {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: readinessPath)
    let byID = store.issuesByID

    func edge(_ id: String) -> Dependency? { byID[id]?.dependencies.first }

    #expect(edge("rdy-7")?.type == .waitsFor)
    #expect(edge("rdy-7")?.type.isBlocking == true)
    #expect(edge("rdy-8")?.type == .conditionalBlocks)
    #expect(edge("rdy-8")?.type.isBlocking == true)
    #expect(edge("rdy-16")?.type == .parentChild)
    #expect(edge("rdy-16")?.type.isBlocking == false)
    // The dangling reference survives decoding as an ordinary edge.
    #expect(edge("rdy-9")?.dependsOnID == "external:upstream:rdy-404")

    await store.close()
}

@MainActor
@Test("The ready set is the engine's, and it is bv 0.25.2's")
func readinessFixtureActionableIsBvs() async {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: readinessPath)

    // Not reimplemented in Swift: the store holds what the engine computed.
    // Withheld: custom/blocked/deferred statuses, a future deferral, both newer
    // blocking edge types, a missing blocker, and a blocked parent's subtree.
    #expect(store.actionable == bvReady)

    await store.close()
}
