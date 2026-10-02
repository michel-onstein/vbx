import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The sidebar's load-warnings badge, and the dropped-record counts it states
/// from the engine's `load_stats` (vbx-dv5).
@MainActor
@Suite("Warnings badge")
struct WarningsBadgeTests {

    @Test("Dropped records are counted in the badge, as the engine reports them")
    func statesTheCounts() {
        let stats = LoadStats(valid: 4, errors: 2, warnings: ["line 5", "line 6"])
        #expect(WarningsBadge.title(warnings: ["line 5", "line 6"], loadStats: stats)
            == "2 records dropped, 4 loaded")
        #expect(WarningsBadge.title(warnings: [], loadStats: LoadStats(valid: 1, errors: 1))
            == "1 record dropped, 1 loaded")
    }

    @Test("Without load stats the badge counts warnings, as before")
    func countsWarningsWithoutStats() {
        #expect(WarningsBadge.title(warnings: ["a"], loadStats: nil) == "1 load warning")
        #expect(WarningsBadge.title(warnings: ["a", "b"], loadStats: nil) == "2 load warnings")
    }

    @Test("A workspace's dropped records list their reasons when no warning was raised")
    func listsTheDroppedReasons() {
        let stats = LoadStats(valid: 3, errors: 1, warnings: ["skipping malformed JSON on line 2"])
        #expect(WarningsBadge.details(warnings: [], loadStats: stats)
            == ["skipping malformed JSON on line 2"])
        #expect(WarningsBadge.details(warnings: ["own"], loadStats: stats) == ["own"])
    }

    @Test("The badge renders with counts and no warnings")
    func renders() throws {
        let result = try Snapshot.render(
            WarningsBadge(warnings: [], loadStats: LoadStats(valid: 3, errors: 1)),
            name: "warnings-badge-dropped",
            size: CGSize(width: 260, height: 60)
        )
        #expect(result.inkCoverage() > 0.01, "the badge drew nothing")
    }
}
