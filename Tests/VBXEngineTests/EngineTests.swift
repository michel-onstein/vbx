import VBXCore
import Foundation
import Testing

@testable import VBXEngine

/// These tests exercise the real Go engine through the C ABI, so they also
/// serve as the bridge's integration check: memory ownership, envelope
/// decoding, error propagation and cancellation-free lifecycle.
private var fixturePath: String {
    // Tests/VBXEngineTests/EngineTests.swift -> package root -> Fixtures/demo
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@Test("Opening a fixture reports its resolved source and hash")
func openReportsInfo() async throws {
    let engine = BeadsEngine()
    let info = try await engine.open(path: fixturePath)
    defer { Task { await engine.close() } }

    #expect(info.issueCount == 18)
    #expect(info.kind == .jsonl)
    #expect(info.source.hasSuffix("issues.jsonl"))
    #expect(!info.dataHash.isEmpty)
    #expect(info.displayName == "demo")
}

@Test("Issues cross the bridge with their fields intact")
func issuesDecode() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    let issues = try await engine.issues()

    #expect(issues.count == 18)

    let facade = try #require(issues.first { $0.id == "vbx-3" })
    #expect(facade.title == "Swift facade over the C ABI")
    #expect(facade.status == .inProgress)
    #expect(facade.labels.contains("swift"))
    #expect(facade.estimatedMinutes == 480)
    #expect(facade.dependencies.contains { $0.dependsOnID == "vbx-2" })

    // Dates must survive the JSON round-trip, not silently become nil.
    #expect(facade.createdAt != nil)
    #expect(facade.updatedAt != nil)

    await engine.close()
}

@Test("Phase 1 metrics are present immediately after open")
func phase1Immediate() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath, skipPhase2: true)
    let metrics = try await engine.metrics()

    #expect(metrics.nodeCount == 18)
    #expect(metrics.edgeCount > 0)
    #expect(!metrics.topologicalOrder.isEmpty)
    // vbx-3 is depended on by many other beads.
    #expect(metrics.blocks("vbx-3") >= 5)

    await engine.close()
}

@Test("Skipping Phase 2 yields no metric values at all")
func skipPhase2LeavesNoValues() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath, skipPhase2: true)
    let metrics = try await engine.metrics()

    // The whole point: absent, not zero. A zero would read as "not important".
    #expect(metrics.pageRank == nil)
    #expect(metrics.betweenness == nil)

    await engine.close()
}

/// The first recommendation's `actions.unavailable_reason`, read raw.
private func firstUnavailableReason(liveTrackerActions: Bool?) async throws -> String? {
    let engine = BeadsEngine()
    if let liveTrackerActions {
        _ = try await engine.open(
            path: fixturePath, skipPhase2: true, liveTrackerActions: liveTrackerActions)
    } else {
        _ = try await engine.open(path: fixturePath, skipPhase2: true)
    }
    defer { Task { await engine.close() } }
    let data = try await engine.rawJSON("triage")
    let triage = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let recommendations = try #require(triage["recommendations"] as? [[String: Any]])
    let actions = try #require(recommendations.first?["actions"] as? [String: Any])
    return actions["unavailable_reason"] as? String
}

@Test("The app's default open never resolves a live tracker; the CLI's does")
func liveTrackerActionsCrossTheBridge() async throws {
    // The default is the app's: the engine binds no tracker and says so.
    let app = try await firstUnavailableReason(liveTrackerActions: nil)
    #expect(app == "live tracker actions are resolved by vbx-cli, not the app")

    // The CLI's setting reaches the engine and runs bv's own resolution, which
    // refuses the demo fixture for want of tracker metadata — before it would
    // ever run `br`. A different reason is the proof the flag crossed the ABI.
    let cli = try await firstUnavailableReason(liveTrackerActions: true)
    #expect(cli == "source has no readable tracker metadata")
}

@Test("Phase 2 metrics arrive and rank the deepest blocker highest")
func phase2Metrics() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    let metrics = try await engine.waitForPhase2()

    #expect(metrics.phase2Ready)
    let pageRank = try #require(metrics.pageRank)
    #expect(pageRank.count == 18)

    // vbx-3 blocks the most work, so it must carry the highest PageRank.
    let top = pageRank.max { $0.value < $1.value }
    #expect(top?.key == "vbx-3")

    #expect(metrics.status?.pageRank?.state == .computed)

    await engine.close()
}

@Test("Actionable excludes anything with an unresolved blocker")
func actionableSet() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    let actionable = try await engine.actionableIDs()
    let issues = try await engine.issues()
    let byID = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })

    #expect(!actionable.isEmpty)
    for id in actionable {
        let issue = try #require(byID[id])
        // bv gates actionability on "not closed-like", not on "open", so a bead
        // whose *status* reads blocked or deferred is still actionable when
        // nothing actually blocks it. Only closed work is excluded.
        #expect(!issue.status.isClosed)
        #expect(!issue.status.isTombstone)

        // The real invariant: no blocking dependency is still unresolved.
        for dep in issue.blockingDependencies {
            if let blocker = byID[dep.dependsOnID] {
                #expect(blocker.status.isClosed, "\(id) is actionable but blocked by open \(blocker.id)")
            }
        }
    }
    await engine.close()
}

@Test("Unblocks reports what closing a bead would free")
func unblocks() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    // Closing vbx-3 should unblock the views that wait on it.
    let freed = try await engine.unblocks("vbx-3")
    #expect(freed.contains("vbx-4"))
    #expect(freed.contains("vbx-5"))

    await engine.close()
}

@Test("The execution plan groups actionable work into tracks")
func executionPlan() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    let plan = try await engine.executionPlan()

    #expect(!plan.tracks.isEmpty)
    // Decoding must actually populate items; bv names them track_id/items, and
    // getting those keys wrong yields silently empty tracks.
    #expect(plan.tracks.allSatisfy { !$0.items.isEmpty })
    #expect(plan.totalActionable > 0)

    let planned = Set(plan.tracks.flatMap { $0.items.map(\.id) })
    let actionable = try await engine.actionableIDs()
    #expect(planned == actionable, "every actionable bead belongs to exactly one track")

    // The summary must name a real bead.
    if !plan.highestImpact.isEmpty {
        #expect(planned.contains(plan.highestImpact))
    }

    await engine.close()
}

@Test("A label scopes triage and the plan to bv's label subgraph")
func labelScopedTriageAndPlan() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    // bv 0.25.2 over the demo: --robot-plan --label engine plans vbx-3 alone,
    // and --robot-triage --label engine recommends vbx-3, vbx-16, vbx-10.
    let plan = try await engine.executionPlan(label: "engine")
    #expect(plan.tracks.flatMap { $0.items.map(\.id) } == ["vbx-3"])
    let triage = try await engine.triage(label: "engine")
    #expect(triage.recommendations.map(\.id) == ["vbx-3", "vbx-16", "vbx-10"])

    // An unknown label is the empty selection, not the whole project.
    #expect(try await engine.executionPlan(label: "no-such-label").tracks.isEmpty)
    #expect(try await engine.triage(label: "no-such-label").recommendations.isEmpty)

    // No label, or an empty one, is the whole project.
    #expect(try await engine.executionPlan(label: "").totalActionable
        == engine.executionPlan().totalActionable)
    #expect(try await engine.executionPlan().totalActionable > 1)

    await engine.close()
}

@Test("An alert label keeps only the alerts on beads carrying it, as bv's --alert-label")
func alertLabelFiltersAlerts() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let all = try await engine.alerts()
    let engineAlerts = try await engine.alerts(alertLabel: "engine")
    let labelled = Set(try await engine.issues().filter { $0.labels.contains("engine") }.map(\.id))

    // Regression (vbx-jnm): every alert was kept whatever the label.
    #expect(!engineAlerts.alerts.isEmpty)
    #expect(engineAlerts.alerts.count < all.alerts.count)
    #expect(engineAlerts.alerts.allSatisfy { labelled.contains($0.issueID) })
    #expect(try await engine.alerts(alertLabel: "no-such-label").alerts.isEmpty)
    #expect(try await engine.alerts(alertLabel: "").alerts.count == all.alerts.count)

    await engine.close()
}

@Test("A capacity label simulates only the beads carrying it, as bv's --capacity-label")
func capacityLabelFiltersTheSimulation() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let all = try await engine.capacity(agents: 1)
    let ui = try await engine.capacity(agents: 1, capacityLabel: "ui")

    // Regression (vbx-ko1): `label` was capacity's filter and judged readiness
    // inside it, so ui beads waiting on an engine bead looked ready.
    #expect(ui.label == "ui")
    #expect(ui.openIssueCount > 0 && ui.openIssueCount < all.openIssueCount)
    #expect(ui.actionable.isEmpty)
    #expect(all.actionable == ["vbx-12", "vbx-14", "vbx-3"])
    let unknown = try await engine.capacity(agents: 1, capacityLabel: "no-such-label")
    #expect(unknown.openIssueCount == 0 && unknown.criticalPath.isEmpty)

    await engine.close()
}

@Test("Graph edges are returned for the dependency DAG")
func graphEdges() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    let edges = try await engine.graphEdges()

    #expect(!edges.isEmpty)
    #expect(edges.contains { $0.from == "vbx-3" && $0.to == "vbx-2" })

    await engine.close()
}

// MARK: - Error handling

@Test("Opening a directory with no bead data throws rather than crashing")
func openMissingWorkspace() async {
    let engine = BeadsEngine()
    await #expect(throws: (any Error).self) {
        try await engine.open(path: NSTemporaryDirectory() + "/vbx-does-not-exist-\(UUID())")
    }
}

@Test("Calling before opening throws notOpen")
func callBeforeOpen() async {
    let engine = BeadsEngine()
    await #expect(throws: (any Error).self) {
        try await engine.issues()
    }
}

@Test("An unknown method surfaces the engine's error, not a crash")
func unknownMethod() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    await #expect(throws: (any Error).self) {
        _ = try await engine.rawJSON("definitely_not_a_method")
    }
    await engine.close()
}

@Test("Repeated open/close cycles do not leak or corrupt state")
func repeatedOpenClose() async throws {
    // Each iteration allocates and frees engine-side buffers; running several
    // rounds catches double-free and use-after-free in the bridge.
    for _ in 0..<5 {
        let engine = BeadsEngine()
        let info = try await engine.open(path: fixturePath)
        #expect(info.issueCount == 18)
        _ = try await engine.issues()
        _ = try await engine.metrics()
        await engine.close()
    }
}

@Test("Reload produces the same hash for unchanged data")
func reloadIsStable() async throws {
    let engine = BeadsEngine()
    let first = try await engine.open(path: fixturePath)
    let second = try await engine.reload()

    // The data hash is the reload gate; identical input must hash identically.
    #expect(first.dataHash == second.dataHash)

    await engine.close()
}

@Test("The correlation report is reachable from the fixture workspace")
func historyReachable() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath, skipPhase2: true)
    defer { Task { await engine.close() } }

    // The fixture lives inside this repository, so the object-store walk has
    // real history to read. If this throws, the message says why — a checkout
    // with no .git is the one legitimate reason.
    let report = try await engine.history(limit: 50)
    #expect(report.stats.totalCommits > 0, "walked no commits; range=\(report.gitRange)")
    #expect(!report.gitRange.isEmpty)
}

// Regression (vbx-850): the Swift copy of bv's IsBlocking drifted from the
// engine when bv v0.25.0 made waits-for and conditional-blocks blocking. This
// pins the two together by asking the engine itself: for every dependency
// type bv defines (plus the legacy empty type and a custom one), a bead whose
// only dependency is an open bead of that type is actionable exactly when
// Swift says the type does not block.
@Test("Swift's isBlocking agrees with the engine for every dependency type")
func blockingAgreesWithEngine() async throws {
    // bv v0.25.2 pkg/model/types.go: DepBlocks … DepDiscoveredFrom.
    let types = [
        "blocks", "conditional-blocks", "waits-for", "related", "parent-child",
        "discovered-from", "", "custom-link",
    ]
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vbx-blocking-\(UUID().uuidString)")
    let beads = root.appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func row(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys), as: UTF8.self)
    }
    let stamp = "2026-10-01T09:00:00Z"
    var lines: [String] = []
    for (n, type) in types.enumerated() {
        lines.append(try row([
            "id": "b-\(n)", "title": "Blocker \(n)", "status": "open", "issue_type": "task",
            "priority": 2, "created_at": stamp, "updated_at": stamp,
        ]))
        lines.append(try row([
            "id": "t-\(n)", "title": "Dependent via '\(type)'", "status": "open", "issue_type": "task",
            "priority": 2, "created_at": stamp, "updated_at": stamp,
            "dependencies": [[
                "issue_id": "t-\(n)", "depends_on_id": "b-\(n)", "type": type, "created_at": stamp,
            ]],
        ]))
    }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: beads.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)

    let engine = BeadsEngine()
    _ = try await engine.open(path: root.path, skipPhase2: true)
    let actionable = try await engine.actionableIDs()
    let issues = try await engine.issues()
    await engine.close()

    for (n, type) in types.enumerated() {
        let dependent = try #require(issues.first { $0.id == "t-\(n)" })
        let dep = try #require(dependent.dependencies.first, "the '\(type)' edge was dropped")
        #expect(dep.type.rawValue == type)
        // Engine: blocked iff not actionable. Swift: blocked iff isBlocking.
        #expect(
            actionable.contains("t-\(n)") == !dep.type.isBlocking,
            "'\(type)': engine says \(actionable.contains("t-\(n)") ? "actionable" : "blocked"), Swift isBlocking=\(dep.type.isBlocking)")
    }
    // The pair that motivated this test, stated outright.
    #expect(!actionable.contains("t-1"), "conditional-blocks must block")
    #expect(!actionable.contains("t-2"), "waits-for must block")
}

@Test("A TOON re-encode restamps the envelope's output_format, and only where the engine set one")
func toonRestampsOutputFormat() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    defer { Task { await engine.close() } }

    let data = try await engine.rawJSON("suggest")
    let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["output_format"] as? String == "json")
    #expect(payload["source_kind"] as? String == "jsonl_local")
    #expect((payload["scope_hash"] as? String)?.count == 64)

    let restamped = RobotEnvelope.stamping(format: "toon", on: payload) as? [String: Any]
    #expect(restamped?["output_format"] as? String == "toon")
    #expect(restamped?["data_hash"] as? String == payload["data_hash"] as? String)

    // No envelope, nothing invented.
    let bare = RobotEnvelope.stamping(format: "toon", on: ["ids": ["a"]]) as? [String: Any]
    #expect(bare?["output_format"] == nil)
    let list = RobotEnvelope.stamping(format: "toon", on: [1, 2]) as? [Int]
    #expect(list == [1, 2])
}
