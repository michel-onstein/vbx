import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The alerts panel and its drift plumbing.
@MainActor
@Suite("Alerts")
struct AlertsTests {

    @Test("Alerts load with the workspace, baseline or not")
    func alertsLoadEagerly() async {
        let store = await Fixture.loadedStore()

        // Unlike history, alerts are cheap once the analysis exists, and they
        // are the one thing a user wants without asking.
        #expect(store.alerts.summary.total == store.alerts.alerts.count)
        // The demo fixture has no saved baseline, which is the normal starting
        // state rather than a failure.
        #expect(!store.alerts.hasBaseline)
        #expect(!store.baseline.exists)

        await store.close()
    }

    @Test("Severity counts add up to the total")
    func countsAddUp() async {
        let store = await Fixture.loadedStore()
        let summary = store.alerts.summary
        #expect(summary.critical + summary.warning + summary.info == summary.total)
        await store.close()
    }

    @Test("Grouping is worst-first and drops empty groups")
    func groupingOrder() {
        let report = AlertReport(alerts: [
            HealthAlert(type: "stale_issue", severity: .info, message: "a"),
            HealthAlert(type: "new_cycle", severity: .critical, message: "b"),
            HealthAlert(type: "stale_issue", severity: .info, message: "c"),
        ])

        let groups = report.grouped
        // Critical then info — warning is absent, so it gets no heading at all.
        #expect(groups.map(\.severity) == [.critical, .info])
        #expect(groups.first?.alerts.count == 1)
        #expect(groups.last?.alerts.count == 2)
    }

    @Test("An empty report groups to nothing")
    func emptyGrouping() {
        #expect(AlertReport.empty.grouped.isEmpty)
        #expect(AlertReport.empty.types.isEmpty)
        #expect(AlertReport.empty.labels.isEmpty)
    }

    @Test("Filter menus offer only the values actually present")
    func filterValues() {
        let report = AlertReport(alerts: [
            HealthAlert(type: "stale_issue", severity: .info, message: "a", label: "core"),
            HealthAlert(type: "new_cycle", severity: .critical, message: "b"),
            HealthAlert(type: "stale_issue", severity: .warning, message: "c", label: "infra"),
        ])
        #expect(report.types == ["new_cycle", "stale_issue"])
        // The alert with no label contributes none, rather than an empty entry.
        #expect(report.labels == ["core", "infra"])
    }

    @Test("An alert's id is stable across reloads")
    func alertIdentityIsStable() {
        // The id is what stops a notification firing again on every reload for
        // a problem that has not changed.
        let first = HealthAlert(
            type: "stale_issue", severity: .critical, message: "vbx-3 is 40 days old",
            issueID: "vbx-3")
        let same = HealthAlert(
            type: "stale_issue", severity: .critical, message: "vbx-3 is 40 days old",
            issueID: "vbx-3")
        let different = HealthAlert(
            type: "stale_issue", severity: .critical, message: "vbx-9 is 40 days old",
            issueID: "vbx-9")

        #expect(first.id == same.id)
        #expect(first.id != different.id)
    }

    @Test("A delta is shown only when there is one")
    func deltaPresence() throws {
        let json = """
            {"type":"pagerank_change","severity":"warning","message":"moved",
             "baseline_value":0.2,"current_value":0.4,"delta":0.2}
            """
        let withDelta = try JSONDecoder().decode(HealthAlert.self, from: Data(json.utf8))
        #expect(withDelta.hasDelta)

        // An issue-derived alert carries no before-and-after. Rendering
        // "0.000 → 0.000" would invent a comparison that was never made.
        let bare = HealthAlert(type: "stale_issue", severity: .info, message: "old")
        #expect(!bare.hasDelta)
    }

    @Test("An unrecognised severity decodes as info rather than throwing")
    func openSeverity() throws {
        let json = """
            {"type":"future_alert","severity":"catastrophic","message":"x"}
            """
        let alert = try JSONDecoder().decode(HealthAlert.self, from: Data(json.utf8))
        // Dropping the whole report because bv added a severity would be worse
        // than under-rating one alert.
        #expect(alert.severity == .info)
        #expect(alert.type == "future_alert")
    }

    @Test("Alert types read as prose")
    func typeDisplayName() {
        let alert = HealthAlert(type: "blocking_cascade", severity: .warning, message: "x")
        #expect(alert.typeDisplayName == "Blocking Cascade")
    }

    @Test("Severities rank worst-first")
    func severityRanking() {
        let ordered = AlertSeverity.allCases.sorted { $0.rank < $1.rank }
        #expect(ordered == [.critical, .warning, .info])
    }

    @Test("Saving a baseline makes drift alerts available")
    func savingBaseline() async throws {
        // Writes into the workspace, so it gets a private copy of the fixture
        // rather than sharing one with every other test running in parallel.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!store.baseline.exists)

        await store.saveBaseline(description: "test baseline")

        // The engine writes to <project>/.bv/baseline.json, so this really
        // does round-trip through disk.
        #expect(store.baseline.exists)
        #expect(store.baseline.description == "test baseline")
        #expect(store.alerts.hasBaseline)

        await store.close()
    }

    @Test("A saved baseline records the workspace's commit, not the process's")
    func baselineCommitIsTheWorkspaces() async throws {
        // The copy sits in a temporary directory, in no repository, so it has
        // no commit to record. The test process runs inside this package's
        // own repository: before vbx-6s8 the engine ran `git` in the process's
        // working directory, and the baseline recorded vbx's HEAD instead.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.saveBaseline(description: "outside any repository")

        #expect(store.baseline.exists)
        #expect(store.baseline.commitSHA.isEmpty, "recorded \(store.baseline.commitSHA)")
        #expect(store.baseline.branch.isEmpty)
        #expect(store.baseline.commitMessage.isEmpty)

        await store.close()
    }

    @Test("The alerts panel renders")
    func rendersPanel() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            AlertsView().environmentObject(store),
            name: "alerts-panel",
            size: CGSize(width: 820, height: 560)
        )
        #expect(result.inkCoverage() > 0.01, "alerts panel drew nothing")
        await store.close()
    }

    @Test("The alerts surface is reachable and distinctly keyed")
    func surfaceIsReachable() {
        #expect(ViewSurface.allCases.contains(.alerts))
        let terminalKeys = ViewSurface.allCases.map(\.terminalKey)
        #expect(Set(terminalKeys).count == terminalKeys.count)
        let commandKeys = ViewSurface.allCases.map(\.keyEquivalent.character)
        #expect(Set(commandKeys).count == commandKeys.count)
    }

    @Test("The notifier is inert without a bundle identifier")
    func notifierIsInert() async {
        // The test process has no bundle id, and
        // UNUserNotificationCenter.current() raises rather than returning nil
        // in that case. Delivering must be a no-op, not a crash.
        let notifier = AlertNotifier()
        await notifier.deliver([
            HealthAlert(type: "new_cycle", severity: .critical, message: "x")
        ])
        // Reaching here at all is the assertion.
        #expect(Bool(true))
    }
}
