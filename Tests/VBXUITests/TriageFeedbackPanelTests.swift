import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The triage panel's feedback controls: Accept / Not now on each
/// recommendation, and the line saying how many verdicts there are and whether
/// they shape the ranking yet (vbx-442).
///
/// Rendered through `Snapshot.render` — an `NSHostingView` in a window — and
/// asserted on ink scoped to the part under test, since the recommendation
/// rows clear any whole-image threshold by themselves.
@MainActor
@Suite("Triage feedback panel")
struct TriageFeedbackPanelTests {

    private static var feedbackFewPath: String {
        URL(fileURLWithPath: Fixture.path).deletingLastPathComponent()
            .appendingPathComponent("feedback-few").path
    }

    /// A private copy of `Fixtures/feedback-few`: two verdicts, one short of
    /// the three bv needs. `Fixture.copy` keeps only the JSONL, so the
    /// feedback file is put back by hand.
    private func store() async throws -> (ProjectStore, URL) {
        let directory = try Fixture.copy(from: Self.feedbackFewPath, prefix: "vbx-triage-panel")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.feedbackFewPath)
                .appendingPathComponent(".beads/feedback.json"),
            to: directory.appendingPathComponent(".beads/feedback.json"))
        let store = ProjectStore()
        await store.open(path: directory.path)
        return (store, directory)
    }

    private static let size = CGSize(width: 560, height: 520)

    @Test("The line names the count and that the weights wait for three")
    func summaryText() {
        let none = TriageFeedback(minSamples: 3)
        #expect(
            TriageFeedbackLine.summary(none)
                == "No feedback yet · weights adapt after 3 verdicts")

        let few = TriageFeedback(
            enabled: true, applied: false, minSamples: 3, totalEvents: 2,
            acceptedCount: 1, ignoredCount: 1)
        #expect(
            TriageFeedbackLine.summary(few)
                == "Feedback: 2 verdicts (1 accepted, 1 not now) · not applied yet (3 needed)")

        let one = TriageFeedback(
            enabled: true, minSamples: 3, totalEvents: 1, acceptedCount: 1)
        #expect(TriageFeedbackLine.summary(one).hasPrefix("Feedback: 1 verdict ("))

        // `applied` is the engine's flag, read as given: a block that says
        // applied is shown as applied, whatever the count looks like.
        let applied = TriageFeedback(
            enabled: true, applied: true, minSamples: 3, totalEvents: 3,
            acceptedCount: 2, ignoredCount: 1)
        #expect(
            TriageFeedbackLine.summary(applied)
                == "Feedback: 3 verdicts (2 accepted, 1 not now) · applied to the ranking")
    }

    @Test("Accept and Not now are distinct, and fill once given")
    func verdictSymbols() {
        #expect(TriageVerdictButtons.symbol(.accept, chosen: false) == "hand.thumbsup")
        #expect(TriageVerdictButtons.symbol(.accept, chosen: true) == "hand.thumbsup.fill")
        #expect(TriageVerdictButtons.symbol(.ignore, chosen: false) == "hand.thumbsdown")
        #expect(TriageVerdictButtons.title(.ignore) == "Not now")
        // Every symbol named must exist, or the button renders as nothing.
        for verdict in [TriageVerdict.accept, .ignore] {
            for chosen in [false, true] {
                let name = TriageVerdictButtons.symbol(verdict, chosen: chosen)
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }
    }

    @Test("The panel draws the verdict controls and the not-applied line")
    func panelBeforeThreshold() async throws {
        let (store, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Premise: two verdicts on file, not yet applied.
        let state = try #require(store.triageFeedbackState)
        #expect(state.totalEvents == 2 && !state.applied)
        #expect(!store.triage.recommendations.isEmpty)

        let panel = try Snapshot.render(
            RecommendationsPanel().environmentObject(store),
            name: "triage-feedback-not-applied", size: Self.size)
        #expect(panel.inkCoverage() > 0.015, "panel looks blank")

        // The line alone, hosted the same way: it draws, and an unloaded
        // store — no summary yet — draws nothing, so the ink is the line's.
        let line = try Snapshot.render(
            TriageFeedbackLine().environmentObject(store).padding(8),
            name: "triage-feedback-line", size: CGSize(width: Self.size.width, height: 40))
        let empty = try Snapshot.render(
            TriageFeedbackLine().environmentObject(ProjectStore()).padding(8),
            name: "triage-feedback-line-empty", size: CGSize(width: Self.size.width, height: 40))
        #expect(line.inkCoverage() > 0.01, "the feedback line drew nothing")
        #expect(empty.inkCoverage() < 0.001)

        // The two thumbs, for the top recommendation.
        let id = try #require(store.triage.recommendations.first?.id)
        let buttons = try Snapshot.render(
            TriageVerdictButtons(id: id).environmentObject(store),
            name: "triage-verdict-buttons", size: CGSize(width: 60, height: 24))
        #expect(buttons.inkCoverage() > 0.02, "the verdict buttons drew nothing")
        await store.close()
    }

    @Test("After the third verdict the line says applied, and the thumb fills")
    func panelAfterThreshold() async throws {
        let (store, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try #require(store.triage.recommendations.first?.id)

        let outline = try Snapshot.render(
            TriageVerdictButtons(id: id).environmentObject(store),
            name: "triage-verdict-outline", size: CGSize(width: 60, height: 24))

        await store.recordTriageFeedback(.accept, for: id)
        #expect(store.triageFeedbackState?.applied == true)
        #expect(store.triageVerdicts[id] == .accept)

        let filled = try Snapshot.render(
            TriageVerdictButtons(id: id).environmentObject(store),
            name: "triage-verdict-filled", size: CGSize(width: 60, height: 24))
        // A filled thumb lays down more ink than its outline. Scoped to the
        // left half, where the accept button sits.
        let accept = CGRect(x: 0, y: 0, width: 30, height: 24)
        #expect(
            filled.inkCoverage(in: accept) > outline.inkCoverage(in: accept),
            "the accepted thumb did not fill")

        let panel = try Snapshot.render(
            RecommendationsPanel().environmentObject(store),
            name: "triage-feedback-applied", size: Self.size)
        #expect(panel.inkCoverage() > 0.015)
        await store.close()
    }
}
