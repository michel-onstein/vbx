import Foundation
import Testing

@testable import VBXCore

private typealias Bead = VBXCore.Issue

/// Which beads differ from the last commit.
///
/// The comparison is pure, which is where the substance is — the git read and
/// the row tint are plumbing around this.
@Suite("Dirty beads")
struct DirtyBeadsTests {

    private func bead(_ id: String, title: String = "t", priority: Int = 2) -> Bead {
        var issue = Bead(id: id, title: title)
        issue.priority = priority
        return issue
    }

    @Test("An unchanged set is clean")
    func nothingChanged() {
        let beads = [bead("vbx-1"), bead("vbx-2")]
        let state = BeadDirtyState.compare(working: beads, committed: beads)
        #expect(state.isClean)
        #expect(state.total == 0)
        #expect(state.marked.isEmpty)
        // Clean is a *known* answer, unlike having nothing to compare against.
        #expect(state.isKnown)
    }

    @Test("The three cases are distinguished")
    func changedAddedRemoved() {
        let committed = [bead("vbx-1", priority: 2), bead("vbx-2"), bead("vbx-3")]
        let working = [
            bead("vbx-1", priority: 0),  // changed
            bead("vbx-2"),  // untouched
            bead("vbx-4"),  // added
        ]  // vbx-3 removed

        let state = BeadDirtyState.compare(working: working, committed: committed)
        #expect(state.changed == ["vbx-1"])
        #expect(state.added == ["vbx-4"])
        #expect(state.removed == ["vbx-3"])
        #expect(state.total == 3)
    }

    @Test("A row is marked for a change or an addition, never for a removal")
    func markedCoversWhatIsOnScreen() {
        let state = BeadDirtyState(
            changed: ["a"], added: ["b"], removed: ["c"])
        #expect(state.marked == ["a", "b"])
        // Nothing on screen represents a deleted bead, so it cannot be marked —
        // but it still counts towards what a commit would carry.
        #expect(!state.isDirty("c"))
        #expect(state.total == 3)
    }

    @Test("Every marked row can say why, and unmarked rows say nothing")
    func reasonsAreAvailable() {
        // Colour alone is not an affordance: a tinted row has to be able to
        // explain itself.
        let state = BeadDirtyState(changed: ["a"], added: ["b"], removed: ["c"])
        #expect(state.reason(for: "a") == "Modified since the last commit")
        #expect(state.reason(for: "b") == "Added since the last commit")
        #expect(state.reason(for: "c") == nil)
        #expect(state.reason(for: "unknown") == nil)
    }

    @Test("Nothing to compare against is not the same as clean")
    func unknownIsNotClean() {
        // A workspace with no repository must not render as one with nothing
        // outstanding. Absent, never zero.
        let unknown = BeadDirtyState.unknown
        #expect(!unknown.isKnown)
        #expect(!unknown.isClean)
        #expect(unknown.total == 0)
        #expect(!unknown.isDirty("anything"))
    }

    @Test("A record differing only in its timestamp is dirty")
    func timestampCounts() {
        // `br` stamps updated_at on every write, so a record differing only
        // there is still a record that was written and is not yet committed.
        // Calling it clean would be calling a real pending change nothing.
        var before = bead("vbx-1")
        before.updatedAt = Date(timeIntervalSince1970: 1_000)
        var after = before
        after.updatedAt = Date(timeIntervalSince1970: 2_000)

        let state = BeadDirtyState.compare(working: [after], committed: [before])
        #expect(state.changed == ["vbx-1"])
    }

    @Test("Order does not make a set look changed")
    func orderIsIrrelevant() {
        // `.beads/issues.jsonl` is a whole-file export and `br` rewrites all of
        // it, so record order moves without any bead moving. Comparing by id
        // rather than position is what keeps a reflow from lighting up
        // every row.
        let a = bead("vbx-1")
        let b = bead("vbx-2")
        let state = BeadDirtyState.compare(working: [b, a], committed: [a, b])
        #expect(state.isClean, "reordering was read as a change")
    }

    // MARK: - The summary, which is what a deletion gets instead of a row

    @Test("A deletion is named, because it has no row to notice")
    func summaryNamesRemovedBeads() {
        // The decision in ADR-015: no synthesised rows for deleted beads. So
        // the only place a deletion can be seen is this string, and a count
        // alone would not say which bead went.
        let state = BeadDirtyState(
            changed: ["vbx-1", "vbx-2"], added: ["vbx-3"], removed: ["vbx-9", "vbx-4"])
        let summary = state.summary()
        #expect(summary.contains("2 modified"))
        #expect(summary.contains("1 added"))
        #expect(summary.contains("2 removed"))
        #expect(summary.contains("vbx-4"), "the removed bead is not named: \(summary)")
        #expect(summary.contains("vbx-9"))
        // Sorted, so the same state always reads the same way — a tooltip that
        // reorders itself between renders looks like something changed.
        #expect(summary.range(of: "vbx-4")!.lowerBound < summary.range(of: "vbx-9")!.lowerBound)
    }

    @Test("Naming is bounded, and says what it left out")
    func summaryIsBounded() {
        // A hundred deleted beads is exactly where an unbounded tooltip stops
        // being useful, and silently truncating would misreport the state.
        let removed = Set((1...10).map { "vbx-\($0)" })
        let summary = BeadDirtyState(removed: removed).summary(namingUpTo: 3)
        #expect(summary.contains("10 removed"))
        #expect(summary.contains("+7 more"), "\(summary)")
    }

    @Test("Clean and unknown do not read the same")
    func summaryDistinguishesCleanFromUnknown() {
        // The rule this repo applies everywhere: absent is not zero. A
        // workspace with no history must not claim nothing is outstanding.
        #expect(BeadDirtyState().summary() == "Nothing uncommitted")
        #expect(BeadDirtyState.unknown.summary() == "No commit to compare against")
    }

    @Test("A deleted bead is not marked, because it has no row")
    func removedBeadsAreNotMarked() {
        // The other half of the same decision: `mark(for:)` answers only for
        // beads that are on screen. If a `-` ever appears, this is the test
        // that should have been reconsidered first.
        let state = BeadDirtyState(removed: ["vbx-9"])
        #expect(state.mark(for: "vbx-9") == nil)
        #expect(state.total == 1, "a deletion still counts towards the commit")
    }
}
