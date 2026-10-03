import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Exercises the exact state object the SwiftUI views bind to, so the app's
/// data layer is verified even where the UI itself cannot be driven headlessly.
private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@MainActor
@Test("Opening a workspace populates every published collection")
func storeLoads() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    #expect(store.loadError == nil)
    #expect(store.isLoaded)
    #expect(store.issues.count == 18)
    #expect(store.metrics.nodeCount == 18)
    #expect(!store.actionable.isEmpty)
    #expect(!store.plan.tracks.isEmpty)
    #expect(!store.edges.isEmpty)
    // Opening selects something so the inspector is never blank on launch.
    #expect(store.focusedID != nil)

    await store.close()
}

@MainActor
@Test("A multi-repository session reports the workspace kind and its root's name")
func storeReportsWorkspaceKind() async {
    // vbx-j7r: the kind decoded as JSONL, so the status bar said "JSONL" and
    // the window was titled ".bv". The configuration is opened explicitly
    // (ADR-026): inside this checkout, discovery from the fixture's root
    // would reach the repository's own .beads.
    let config = URL(fileURLWithPath: fixturePath)
        .deletingLastPathComponent()
        .appendingPathComponent("dropped-workspace/.bv/workspace.yaml")
        .path
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: config)

    #expect(store.loadError == nil)
    #expect(store.info?.kind == .workspace)
    #expect(store.info?.displayName == "dropped-workspace")
    await store.close()

    await store.open(path: fixturePath)
    #expect(store.info?.kind == .jsonl)
    await store.close()
}

@MainActor
@Test("A multi-repository workspace offers no time travel, and says why")
func workspaceOffersNoTimeTravel() async {
    // vbx-bcq, ADR-028: the fixture's yaml sits in this checkout, so the
    // scrubber offered this repository's commits to it, and comparing against
    // HEAD read the yaml as the beads and called every bead new.
    let config = URL(fileURLWithPath: fixturePath)
        .deletingLastPathComponent()
        .appendingPathComponent("dropped-workspace/.bv/workspace.yaml")
        .path
    let store = ProjectStore()
    store.skipPhase2 = true

    // A single repository first: what it loaded must not follow the switch.
    await store.open(path: fixturePath)
    #expect(store.timeTravelUnavailableReason == nil)
    await store.loadRevisions()

    await store.open(path: config)
    #expect(store.info?.kind == .workspace)
    #expect(store.timeTravelUnavailableReason != nil)
    #expect(store.revisions.revisions.isEmpty)

    await store.loadRevisions()
    #expect(store.revisions.revisions.isEmpty)
    // A state the engine refuses on purpose, not a failed read.
    #expect(store.unavailableReason(.revisions) == nil)

    await store.travel(to: "HEAD")
    #expect(!store.isTimeTravelling)
    #expect(store.timeTravel.badges.isEmpty)
    #expect(store.pastIssues.isEmpty)
    await store.close()
}

@MainActor
@Test("A failed open reports the error and clears stale state")
func storeHandlesFailure() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)
    #expect(store.isLoaded)

    // Opening a bad path must not leave the previous workspace's data on screen.
    await store.open(path: NSTemporaryDirectory() + "/vbx-missing-\(UUID())")

    #expect(store.loadError != nil)
    #expect(!store.isLoaded)
    #expect(store.issues.isEmpty)
    #expect(store.actionable.isEmpty)
    #expect(store.plan.tracks.isEmpty)
    #expect(store.metrics.nodeCount == 0)
}

@MainActor
@Test("Phase 2 completes and unlocks the metric-dependent views")
func storeComputesPhase2() async {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: fixturePath)

    // Skipped: no values at all, rather than zeros.
    #expect(store.metrics.pageRank == nil)

    await store.computePhase2()
    #expect(store.metrics.phase2Ready)
    #expect(store.metrics.pageRank?.isEmpty == false)

    await store.close()
}

@MainActor
@Test("The filter drives what the views actually show")
func storeFiltering() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    store.query.filter = .all
    let all = store.visibleIssues.count

    store.query.filter = .closed
    let closed = store.visibleIssues
    #expect(closed.allSatisfy { $0.status.isClosed })
    #expect(closed.count < all)

    store.query.filter = .ready
    let ready = store.visibleIssues
    #expect(ready.allSatisfy { store.actionable.contains($0.id) })

    await store.close()
}

@MainActor
@Test("Search narrows the visible set")
func storeSearch() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    store.query.filter = .all
    store.query.searchText = "graph"
    let hits = store.visibleIssues
    #expect(!hits.isEmpty)
    #expect(hits.count < store.issues.count)

    store.query.searchText = "zzzz-no-such-bead"
    #expect(store.visibleIssues.isEmpty)

    await store.close()
}

@MainActor
@Test("Dependency navigation resolves both directions")
func storeDependencyNavigation() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let facade = try? #require(store.issuesByID["vbx-3"])
    guard let facade else { return }

    // vbx-3 waits on vbx-2 ...
    let blockers = store.blockers(of: facade)
    #expect(blockers.contains { $0.0.dependsOnID == "vbx-2" })
    // ... and the target resolves to a real issue, not a dangling id.
    #expect(blockers.allSatisfy { $0.1 != nil })

    // ... and several beads wait on vbx-3.
    let dependents = store.dependents(of: facade)
    #expect(dependents.count >= 5)

    await store.close()
}

@MainActor
@Test("Reload keeps the workspace stable")
func storeReload() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)
    let before = store.info?.dataHash

    await store.reload()

    #expect(store.loadError == nil)
    #expect(store.info?.dataHash == before)
    #expect(store.issues.count == 18)

    await store.close()
}

@MainActor
@Test("The summary line describes the loaded workspace")
func storeSummary() async {
    let store = ProjectStore()
    #expect(store.summaryLine() == "no workspace")

    await store.open(path: fixturePath)
    let summary = store.summaryLine()
    #expect(summary.contains("demo"))
    #expect(summary.contains("18 beads"))

    await store.close()
}

@MainActor
@Test("Selecting by id ignores an id the workspace does not hold")
func storeSelectGuardsStaleIDs() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    #expect(store.select(id: "vbx-3"))
    #expect(store.focusedID == "vbx-3")

    // A description can outlive the bead it cites. Following a stale
    // reference must leave the current selection alone rather than clear it.
    #expect(!store.select(id: "vbx-does-not-exist"))
    #expect(store.focusedID == "vbx-3")

    await store.close()
}

@MainActor
@Test("Bead titles are exposed for linkifying ids mentioned in prose")
func storeBeadTitles() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    #expect(store.beadTitles.count == store.issues.count)
    #expect(store.beadTitles["vbx-3"] == store.issuesByID["vbx-3"]?.title)

    await store.close()
}
