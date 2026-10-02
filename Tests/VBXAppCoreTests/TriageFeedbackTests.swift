import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Accept / Not now / Reset from the triage panel (vbx-442).
///
/// Each goes through the engine's `triage_feedback_*` methods, which write
/// `.beads/feedback.json` with bv's own functions, and then through the same
/// reload an outside `bv --feedback-accept` would trigger. So what these
/// assert is the whole round trip: the file on disk, and the ranking that
/// comes back from it — never a number the store worked out itself.

/// `Fixtures/feedback-few`: eight beads and two verdicts, one short of the
/// three bv needs before it applies the weights. Copied, because these tests
/// write; `withFeedback: false` leaves the feedback file behind.
private func scratchWorkspace(withFeedback: Bool = true) throws -> URL {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/feedback-few/.beads")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-triage-feedback-\(UUID().uuidString)")
    let beads = dir.appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    var files = ["issues.jsonl"]
    if withFeedback { files.append("feedback.json") }
    for file in files {
        try FileManager.default.copyItem(
            at: fixture.appendingPathComponent(file), to: beads.appendingPathComponent(file))
    }
    return dir
}

/// The verdicts in a workspace's feedback.json, as bv wrote them.
private func events(in dir: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: dir.appendingPathComponent(".beads/feedback.json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["events"] as? [[String: Any]] ?? []
}

/// Whether two rankings differ in any score by more than rounding.
///
/// Not exact equality: triage reads the wall clock, and staleness moves by a
/// hair between two loads a second apart. A weight change moves scores by far
/// more than that.
private func scoresMoved(_ a: [Recommendation], _ b: [Recommendation]) -> Bool {
    let before = Dictionary(a.map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })
    return b.contains { rec in
        guard let old = before[rec.id] else { return true }
        return abs(old - rec.score) > 0.001
    }
}

@MainActor
@Test("The third verdict writes feedback.json, applies the weights and re-ranks")
func acceptAppliesWeightsOnTheThirdVerdict() async throws {
    let dir = try scratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProjectStore()
    await store.open(path: dir.path)

    let before = store.triage.recommendations
    let id = try #require(before.first?.id)
    let state = try #require(store.triageFeedbackState)
    #expect(state.totalEvents == 2 && !state.applied && state.minSamples == 3)

    await store.recordTriageFeedback(.accept, for: id)

    #expect(store.triageFeedbackError == nil)
    let written = try events(in: dir)
    #expect(written.count == 3)
    #expect(written.last?["issue_id"] as? String == id)
    #expect(written.last?["action"] as? String == "accept")

    // Re-ranked by the reload the write triggered — nothing reloaded by hand.
    #expect(store.triage.feedback?.applied == true)
    #expect(store.triageFeedbackState?.totalEvents == 3)
    #expect(store.triageFeedbackState?.acceptedCount == 2)
    #expect(scoresMoved(before, store.triage.recommendations), "applied weights changed no score")
    #expect(store.triageVerdicts[id] == .accept)
    await store.close()
}

@MainActor
@Test("A first verdict creates feedback.json and leaves the ranking alone")
func ignoreBelowTheThresholdDoesNotReweight() async throws {
    let dir = try scratchWorkspace(withFeedback: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProjectStore()
    await store.open(path: dir.path)

    // No file: triage carries no block, and the summary still comes from the
    // engine, with bv's threshold in it.
    #expect(store.triage.feedback == nil)
    #expect(store.triageFeedbackState?.totalEvents == 0)
    #expect(store.triageFeedbackState?.minSamples == 3)

    let before = store.triage.recommendations
    let id = try #require(before.last?.id)
    await store.recordTriageFeedback(.ignore, for: id)

    let written = try events(in: dir)
    #expect(written.count == 1)
    #expect(written.first?["action"] as? String == "ignore")
    let state = try #require(store.triage.feedback)
    #expect(state.totalEvents == 1 && state.ignoredCount == 1 && !state.applied)
    #expect(!scoresMoved(before, store.triage.recommendations), "one verdict reweighted triage")
    #expect(before.map(\.id) == store.triage.recommendations.map(\.id))
    #expect(store.triageVerdicts[id] == .ignore)
    await store.close()
}

@MainActor
@Test("Reset empties feedback.json and returns triage to the default weights")
func resetReturnsToDefaultWeights() async throws {
    let dir = try scratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProjectStore()
    await store.open(path: dir.path)

    // Two verdicts are on file but not applied: this is the default ranking.
    let defaults = store.triage.recommendations
    let id = try #require(defaults.first?.id)
    await store.recordTriageFeedback(.accept, for: id)
    #expect(store.triage.feedback?.applied == true)

    await store.resetTriageFeedback()

    #expect(store.triageFeedbackError == nil)
    #expect(try events(in: dir).isEmpty)
    // bv omits the block for an empty history; the summary says zero and
    // still names the threshold.
    #expect(store.triage.feedback == nil)
    #expect(store.triageFeedbackState?.totalEvents == 0)
    #expect(store.triageFeedbackState?.minSamples == 3)
    #expect(!scoresMoved(defaults, store.triage.recommendations))
    #expect(store.triageVerdicts.isEmpty)
    await store.close()
}

/// The App Store build holds the workspace read-only (ADR-025), so the
/// engine's in-process write is refused there. That must reach the panel as an
/// error and change nothing — not record a verdict the file never got.
@MainActor
@Test("A workspace the process cannot write reports the error and changes nothing")
func deniedWriteReportsAndChangesNothing() async throws {
    let dir = try scratchWorkspace(withFeedback: false)
    let beads = dir.appendingPathComponent(".beads")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: beads.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let store = ProjectStore()
    await store.open(path: dir.path)
    let id = try #require(store.triage.recommendations.first?.id)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: beads.path)
    await store.recordTriageFeedback(.accept, for: id)

    let error = try #require(store.triageFeedbackError)
    #expect(error.contains("saving feedback"), "unexpected error: \(error)")
    #expect(!FileManager.default.fileExists(atPath: beads.appendingPathComponent("feedback.json").path))
    #expect(store.triageVerdicts.isEmpty)
    #expect(store.triageFeedbackState?.totalEvents == 0)
    await store.close()
}
