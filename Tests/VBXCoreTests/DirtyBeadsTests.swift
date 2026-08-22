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
}
