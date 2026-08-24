import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// A closed bead is a record of what happened, so vbx does not offer the edit.
///
/// **`br` does not enforce this.** Checked against a scratch workspace before
/// any of it was written: `br update` retitles and re-prioritises a closed issue
/// and exits 0. So this is vbx's own rule, gated in the UI *and* refused at the
/// write — a rule enforced only where the affordance is drawn is one a stale
/// view can walk straight past.
@MainActor
@Suite("Immutable closed beads")
struct ImmutableClosedBeadsTests {

    @Test("A closed bead refuses, and says how to proceed")
    func closedBeadRefuses() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let closed = try #require(store.issues.first(where: { $0.status.isImmutable })?.id)
        let reason = try #require(
            store.editingUnavailableReason(for: [closed]),
            "a closed bead was offered for editing")
        // The escape hatch is named, because "no" without a way forward is the
        // thing that makes a rule feel arbitrary.
        #expect(reason.contains("Reopen"), "\(reason)")
        #expect(!store.canEdit([closed]))
    }

    @Test("An open bead is untouched by the rule")
    func openBeadStillEdits() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let open = try #require(store.issues.first(where: { !$0.status.isImmutable })?.id)
        #expect(store.editingUnavailableReason(for: [open]) == nil)
        #expect(store.canEdit([open]))
    }

    @Test("A mixed selection refuses as a whole, and counts what stopped it")
    func mixedSelectionRefuses() async throws {
        // The decision the bead asked for: refuse rather than apply to the open
        // beads and skip the closed ones. Partial success is noticed a week
        // later, when the beads that did not change look like beads nobody got
        // to — so the command is one rule, and the reason carries the count so
        // the refusal is never mysterious.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let closed = try #require(store.issues.first(where: { $0.status.isImmutable })?.id)
        let open = try #require(store.issues.first(where: { !$0.status.isImmutable })?.id)

        let reason = try #require(store.editingUnavailableReason(for: [closed, open]))
        #expect(reason.contains("1 of 2"), "\(reason)")
        #expect(reason.contains("narrow the selection"), "\(reason)")
    }

    @Test("An id that is not in the workspace does not refuse for the others")
    func staleIDsAreIgnored() async throws {
        // A stale selection is a reason to write nothing for that id, not to
        // refuse the ids that are real — otherwise a reload that dropped a bead
        // silently disables editing for everything selected with it.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let open = try #require(store.issues.first(where: { !$0.status.isImmutable })?.id)
        #expect(store.editingUnavailableReason(for: [open, "vbx-gone"]) == nil)
    }

    @Test("The write refuses too, not only the affordance")
    func theWriteItselfRefuses() async throws {
        // The end-to-end half, through `br` against a real workspace: the UI
        // gate is what the user meets, but a gate is not a rule if the thing
        // behind it still says yes. `br` itself says yes — that was measured —
        // so this is the only thing standing between a stale view and a
        // rewritten record.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let closed = try #require(store.issues.first(where: { $0.status.isImmutable })?.id)
        let before = try #require(store.issues.first(where: { $0.id == closed }))

        let failed = await store.setPriority(before.priority == 0 ? 3 : 0, for: [closed])
        #expect(failed == [closed], "the write was not refused")

        let titleWritten = await store.setTitle("Rewritten history", for: closed)
        #expect(!titleWritten, "the title write was not refused")

        let after = try #require(store.issues.first(where: { $0.id == closed }))
        #expect(after.priority == before.priority, "the priority changed on a closed bead")
        #expect(after.title == before.title, "the title changed on a closed bead")
    }

    @Test("The refusal takes the tooltip from a column that edits, and only there")
    func tooltipPrefersTheRefusal() {
        // A refusal explains an affordance that just did nothing, which is the
        // more urgent question than "this row is uncommitted" — but only on a
        // column that would otherwise have accepted the edit. On a column that
        // never edits it would be answering a question nobody asked.
        let refusal = "A closed bead is a record of what happened. Reopen it to edit."
        let uncommitted = "Modified since the last commit"

        #expect(
            BeadTable.Coordinator.tooltip(
                editRefusal: refusal, columnEdits: true, uncommittedReason: uncommitted)
                == refusal)
        #expect(
            BeadTable.Coordinator.tooltip(
                editRefusal: refusal, columnEdits: false, uncommittedReason: uncommitted)
                == uncommitted)
        // Nothing to say about the commit: the refusal is better than silence
        // even on a column that does not edit.
        #expect(
            BeadTable.Coordinator.tooltip(
                editRefusal: refusal, columnEdits: false, uncommittedReason: nil) == refusal)
        #expect(
            BeadTable.Coordinator.tooltip(
                editRefusal: nil, columnEdits: true, uncommittedReason: nil) == "")
    }
}
