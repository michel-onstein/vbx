import VBXCore
import Foundation
import Testing

@testable import VBXEngine

/// The app's hybrid search goes through the same engine call as
/// `vbx-cli --robot-search`, so bv's guaranteed exact-id hit reaches the
/// search field too (vbx-52c). `Fixtures/search` buries tax-7 below beads
/// whose text is all "tax 7", so only the guarantee can put it first.
private var searchFixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/search")
        .path
}

@Test("A bead id typed into search returns that bead first, in both modes")
func exactIDIsGuaranteed() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: searchFixturePath, skipPhase2: true)
    defer { Task { await engine.close() } }

    // The control: the same words, not spelled as the id, never reach it.
    let control = try await engine.search("tax 7", mode: .text, limit: 3)
    #expect(!control.results.contains { $0.issueID == "tax-7" })

    for mode in [SearchMode.text, .hybrid] {
        let results = try await engine.search("tax-7", mode: mode, limit: 3)
        #expect(results.results.first?.issueID == "tax-7", "\(mode)")
        #expect(results.results.count == 3, "\(mode)")
    }
}
