import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// bv 0.25's alert fields — `suggested_action`, `labels`, `related_issue_id` —
/// and the six alert types it added, from decoding through to the panel.
@MainActor
@Suite("Alert actions")
struct AlertActionTests {

    /// Two alerts exactly as `vbx-cli --robot-alerts` prints them over
    /// `Fixtures/demo`, which is bv 0.25.2's shape (parity-checked).
    static let demoJSON = """
        {"has_baseline":false,"summary":{"total":2,"critical":0,"warning":2,"info":0},
         "alerts":[
          {"unblocks_count":6,"labels":["engine","swift"],"type":"high_impact_unblock",
           "severity":"warning","details":["vbx-11","vbx-4","vbx-5"],
           "suggested_action":"Schedule this issue next; it releases high-priority downstream work",
           "message":"Completing vbx-3 unblocks 6 item(s), 3 of them at P1 or higher",
           "issue_id":"vbx-3","detected_at":"2026-10-02T02:29:49.491876Z"},
          {"labels":["engine","swift"],"type":"abandoned_claim","severity":"warning",
           "details":["assignee=michel","last_update=2026-08-10T12:00:00Z","threshold_days=14"],
           "suggested_action":"Ask the assignee for status, or release the claim so the issue returns to the ready queue",
           "message":"Claim on vbx-3 by michel idle for 53 days","issue_id":"vbx-3",
           "detected_at":"2026-10-02T02:29:49.491876Z"}
         ]}
        """

    private func decode(_ json: String) throws -> HealthAlert {
        try JSONDecoder().decode(HealthAlert.self, from: Data(json.utf8))
    }

    @Test("The demo's alerts decode with their suggested action and labels")
    func decodesDemoAlerts() throws {
        let report = try JSONDecoder().decode(AlertReport.self, from: Data(Self.demoJSON.utf8))
        #expect(report.alerts.count == 2)

        let unblock = try #require(report.alerts.first { $0.type == "high_impact_unblock" })
        #expect(
            unblock.suggestedAction
                == "Schedule this issue next; it releases high-priority downstream work")
        #expect(unblock.labels == ["engine", "swift"])
        #expect(unblock.unblocksCount == 6)

        let claim = try #require(report.alerts.first { $0.type == "abandoned_claim" })
        #expect(claim.suggestedAction?.hasPrefix("Ask the assignee for status") == true)
        #expect(claim.labels == ["engine", "swift"])
        #expect(claim.relatedIssueID.isEmpty)
    }

    @Test("A related bead decodes")
    func decodesRelatedIssue() throws {
        let alert = try decode(
            """
            {"type":"potential_duplicate","severity":"info","message":"vbx-2 and vbx-9 look alike",
             "issue_id":"vbx-2","related_issue_id":"vbx-9",
             "suggested_action":"Review both issues and close one as a duplicate"}
            """)
        #expect(alert.relatedIssueID == "vbx-9")
        #expect(alert.typeDisplayName == "Potential Duplicate")
    }

    @Test("An alert from before bv 0.25 keeps its new fields absent")
    func absentStaysAbsent() throws {
        let alert = try decode(#"{"type":"stale_issue","severity":"info","message":"old"}"#)
        // Nil, not "": an empty action would draw an empty remedy line.
        #expect(alert.suggestedAction == nil)
        #expect(alert.labels.isEmpty)
        #expect(alert.relatedIssueID.isEmpty)

        let blank = try decode(
            #"{"type":"stale_issue","severity":"info","message":"old","suggested_action":"  "}"#)
        #expect(blank.suggestedAction == nil)
    }

    @Test("A new field in an unexpected shape costs the field, not the alert")
    func tolerantDecoding() throws {
        let json = """
            {"alerts":[
              {"type":"some_future_alert","severity":"warning","message":"a",
               "suggested_action":{"command":"br update vbx-1"},"labels":"engine",
               "related_issue_id":7,"brand_new_field":[1,2,3]},
              {"type":"stale_issue","severity":"info","message":"b"}
            ]}
            """
        let report = try JSONDecoder().decode(AlertReport.self, from: Data(json.utf8))
        // Dropping an alert silently changes the counts the panel shows.
        #expect(report.alerts.count == 2)
        let future = try #require(report.alerts.first)
        #expect(future.message == "a")
        #expect(future.suggestedAction == nil)
        #expect(future.labels.isEmpty)
        #expect(future.relatedIssueID.isEmpty)
    }

    @Test("Every bv 0.25.2 alert type has a name and a symbol that exists")
    func knownTypesHaveSymbols() {
        let bvTypes = [
            "new_cycle", "pagerank_change", "density_growth", "node_count_change",
            "edge_count_change", "blocked_increase", "actionable_change", "stale_issue",
            "velocity_drop", "blocking_cascade", "high_impact_unblock", "abandoned_claim",
            "potential_duplicate", "priority_mismatch", "scope_creep",
        ]
        #expect(Set(HealthAlert.knownTypes.keys) == Set(bvTypes))
        for type in bvTypes {
            let symbol = HealthAlert.symbolName(forType: type)
            #expect(symbol != HealthAlert.fallbackSymbolName, "\(type) uses the fallback")
            // A misspelt symbol name draws nothing, silently.
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "\(symbol) is not an SF Symbol")
        }
        #expect(HealthAlert.displayName(forType: "pagerank_change") == "PageRank Change")
        #expect(HealthAlert.displayName(forType: "high_impact_unblock") == "High-Impact Unblock")
    }

    @Test("An unknown alert type falls back to a generic name and symbol")
    func unknownTypeFallsBack() throws {
        let alert = try decode(#"{"type":"orbit_decay","severity":"warning","message":"x"}"#)
        #expect(alert.typeDisplayName == "Orbit Decay")
        #expect(alert.typeSymbolName == HealthAlert.fallbackSymbolName)
        #expect(
            NSImage(
                systemSymbolName: HealthAlert.fallbackSymbolName, accessibilityDescription: nil)
                != nil)
    }

    @Test("The label picker offers a bead's labels, which the alert-label filter matches")
    func labelPickerIncludesBeadLabels() {
        // Regression: the picker read only `label`, which bv sets on label-level
        // alerts alone. Every demo alert carries `labels` instead, so the picker
        // was empty and the engine's alert-label filter unreachable.
        let report = AlertReport(alerts: [
            HealthAlert(type: "stale_issue", severity: .info, message: "a", labels: ["ui", "swift"]),
            HealthAlert(type: "scope_creep", severity: .info, message: "b", label: "engine"),
            HealthAlert(
                type: "abandoned_claim", severity: .warning, message: "c", label: "ui",
                labels: ["ui"]),
        ])
        #expect(report.labels == ["engine", "swift", "ui"])
        #expect(report.alerts[2].allLabels == ["ui"])
    }

    @Test("A notification carries the suggested action under the message")
    func notificationBody() {
        let bare = HealthAlert(type: "new_cycle", severity: .critical, message: "cycle")
        #expect(AlertNotifier.body(for: bare) == "cycle")

        let advised = HealthAlert(
            type: "new_cycle", severity: .critical, message: "cycle",
            suggestedAction: "Break the cycle")
        #expect(AlertNotifier.body(for: advised) == "cycle\nBreak the cycle")
    }

    @Test("The demo's alerts reach the store with suggested actions and labels")
    func storeCarriesActions() async throws {
        let store = await Fixture.loadedStore()
        let alerts = store.alerts.alerts
        #expect(!alerts.isEmpty)
        // bv gives every alert it emits an action; the demo is all such.
        #expect(alerts.allSatisfy { $0.suggestedAction != nil })
        #expect(alerts.contains { $0.type == "abandoned_claim" })
        #expect(alerts.contains { $0.type == "high_impact_unblock" })
        #expect(store.alerts.labels.contains("engine"))
        await store.close()
    }

    @Test("Picking a bead label from the panel filters the alerts to it")
    func labelFilterFromPicker() async throws {
        let store = await Fixture.loadedStore()
        let total = store.alerts.alerts.count
        let label = try #require(store.alerts.labels.first)

        store.alertLabelFilter = label
        await store.refreshAlerts()

        #expect(!store.alerts.alerts.isEmpty)
        #expect(store.alerts.alerts.count < total)
        await store.close()
    }

    /// Renders one row at a fixed width and returns it with its natural height.
    private func renderRow(_ alert: HealthAlert, name: String) throws -> (RenderResult, CGFloat) {
        let width: CGFloat = 640
        let height = NSHostingView(rootView: AlertRow(alert: alert).frame(width: width))
            .fittingSize.height
        let result = try Snapshot.render(
            AlertRow(alert: alert).frame(maxHeight: .infinity, alignment: .top),
            name: name,
            size: CGSize(width: width, height: 200))
        return (result, height)
    }

    @Test(
        "A row shows the suggested action under the alert",
        arguments: ["abandoned_claim", "high_impact_unblock"])
    func rowShowsAction(type: String) async throws {
        let store = await Fixture.loadedStore()
        let alert = try #require(store.alerts.alerts.first { $0.type == type })
        try #require(alert.suggestedAction != nil)
        var withoutAction = alert
        withoutAction.suggestedAction = nil

        let (with, withHeight) = try renderRow(alert, name: "alert-row-\(type)")
        let (without, withoutHeight) = try renderRow(
            withoutAction, name: "alert-row-\(type)-no-action")

        // The action is the row's last line, so it adds height below the rest…
        #expect(withHeight > withoutHeight + 8)
        // …and that band holds ink with the action and none without it.
        let band = CGRect(x: 0, y: withoutHeight, width: 640, height: withHeight - withoutHeight)
        #expect(with.inkCoverage(in: band) > 0.02, "no action drawn for \(type)")
        #expect(without.inkCoverage(in: band) < 0.005)
        await store.close()
    }

    @Test("A row draws its labels as chips")
    func rowShowsLabels() throws {
        let base = HealthAlert(
            type: "abandoned_claim", severity: .warning, message: "Claim idle",
            issueID: "vbx-3")
        var labelled = base
        labelled.labels = ["engine", "swift"]

        let (plain, height) = try renderRow(base, name: "alert-row-no-labels")
        let (chips, _) = try renderRow(labelled, name: "alert-row-labels")

        // The id/label line, right of the bead link: empty without labels.
        let band = CGRect(x: 70, y: 20, width: 200, height: max(1, height - 26))
        #expect(chips.inkCoverage(in: band) > plain.inkCoverage(in: band) + 0.02)
    }

    @Test("The panel renders the warning alerts with their actions")
    func panelShowsActions() async throws {
        let store = await Fixture.loadedStore()
        store.alertSeverityFilter = .warning
        await store.refreshAlerts()

        let types = Set(store.alerts.alerts.map(\.type))
        #expect(types.isSuperset(of: ["abandoned_claim", "high_impact_unblock"]))
        #expect(store.alerts.alerts.allSatisfy { $0.suggestedAction != nil })

        let size = CGSize(width: 820, height: 640)
        let result = try Snapshot.render(
            AlertsView().environmentObject(store), name: "alerts-panel-actions", size: size)
        // The list, below the header; the header alone would clear a
        // whole-image threshold.
        let list = CGRect(x: 0, y: 120, width: size.width, height: size.height - 120)
        #expect(result.inkCoverage(in: list) > 0.02, "alert list drew nothing")
        await store.close()
    }
}
