import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

// Swift Testing exports its own `Issue`; the model is the one meant here.
private typealias Bead = VBXCore.Issue

/// Marking beads that are ahead of the last commit.
///
/// The comparison itself is tested in `Dirty beads`. These cover the parts that
/// need a real repository: that `HEAD` is read at all, that a write through
/// `br` shows up, and that the mark reaches the pixels.
@MainActor
@Suite("Uncommitted beads")
struct UncommittedBeadsTests {

    @Test("A freshly committed workspace is clean, and knows it")
    func committedWorkspaceIsClean() async throws {
        let (store, directory) = try await Fixture.committedStore()
        defer {
            // Before the directory goes: the store is still watching it, and
            // now watches `.git` as well. FSEvents delivering a change for a
            // path that has just been deleted, into a store whose engine
            // session is still open, is a crash the parallel suite hit about
            // one run in eight — no failing expectation, just a dead runner.
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        await store.refreshDirtyState()
        // Both halves: known, and empty. "Unknown" would also report zero, and
        // would mean the git read silently failed.
        #expect(store.dirtyBeads.isKnown, "HEAD was not read — nothing to compare against")
        #expect(store.dirtyBeads.isClean)
        #expect(store.dirtyBeads.total == 0)
    }

    @Test("A bead written through br becomes uncommitted; its neighbours do not")
    func writingMakesOneBeadDirty() async throws {
        let (store, directory) = try await Fixture.committedStore()
        defer {
            // Before the directory goes: the store is still watching it, and
            // now watches `.git` as well. FSEvents delivering a change for a
            // path that has just been deleted, into a store whose engine
            // session is still open, is a crash the parallel suite hit about
            // one run in eight — no failing expectation, just a dead runner.
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        let target = try #require(store.visibleIssues.first)
        let untouched = try #require(store.visibleIssues.dropFirst().first)
        let newPriority = target.priority == 0 ? 3 : 0

        let failed = await store.setPriority(newPriority, for: [target.id])
        #expect(failed.isEmpty, "the write failed: \(String(describing: store.loadError))")

        #expect(store.dirtyBeads.isKnown)
        #expect(store.isDirty(target.id), "the edited bead is not marked")
        #expect(
            !store.isDirty(untouched.id),
            "an untouched bead was marked — the comparison is too coarse")
        #expect(store.dirtyBeads.reason(for: target.id) == "Modified since the last commit")
        // The glyph the gutter will draw, from the same state: an edit is `*`,
        // and the bead beside it draws nothing.
        #expect(store.dirtyBeads.mark(for: target.id) == .changed)
        #expect(store.dirtyBeads.mark(for: untouched.id) == nil)
    }

    @Test("A workspace with no repository is unknown, not clean")
    func noRepositoryIsUnknown() async throws {
        // `writableStore` copies the fixture without any git history, which is
        // exactly the case: nothing to compare against.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            // Before the directory goes: the store is still watching it, and
            // now watches `.git` as well. FSEvents delivering a change for a
            // path that has just been deleted, into a store whose engine
            // session is still open, is a crash the parallel suite hit about
            // one run in eight — no failing expectation, just a dead runner.
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        await store.refreshDirtyState()
        #expect(!store.dirtyBeads.isKnown)
        #expect(!store.dirtyBeads.isClean, "no history was reported as nothing outstanding")
        await store.close()
    }

    @Test("HEAD is watched, because a commit does not touch the bead file")
    func headIsWatched() async throws {
        // The bead file is unchanged by a commit — `HEAD` moves and every dirty
        // bead becomes clean. The existing watch would never fire, so this
        // asserts the second watch has something to watch.
        let (store, directory) = try await Fixture.committedStore()
        defer {
            // Before the directory goes: the store is still watching it, and
            // now watches `.git` as well. FSEvents delivering a change for a
            // path that has just been deleted, into a store whose engine
            // session is still open, is a crash the parallel suite hit about
            // one run in eight — no failing expectation, just a dead runner.
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        let head = try #require(store.gitHeadPath, "no .git/HEAD found to watch")
        #expect(head.hasSuffix(".git/HEAD"))
        #expect(FileManager.default.fileExists(atPath: head))
    }

    @Test("Each mark draws its own character, and a clean bead draws none")
    func marksAreDistinct() {
        // The glyph is the whole distinction the tint could not make, so the
        // three cases are asserted as characters rather than as "different".
        #expect(DirtyMarkCell.symbol(for: .added) == "+")
        #expect(DirtyMarkCell.symbol(for: .changed) == "*")
        #expect(DirtyMarkCell.symbol(for: nil).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("An unknown dirty state marks nothing")
    func unknownMarksNothing() {
        // Absent, never zero. The danger is the opposite of a missing mark: a
        // workspace with no history rendering as one with nothing outstanding.
        let unknown = BeadDirtyState.unknown
        #expect(unknown.mark(for: "vbx-1") == nil)
        #expect(!unknown.isKnown)
    }

    @Test("Every mark says what it means")
    func everyMarkHasAReason() {
        // The tooltip is the affordance — a character in a gutter explains
        // nothing on its own. Stated over `allCases` so a third mark cannot be
        // added without one.
        for mark in BeadDirtyState.Mark.allCases {
            #expect(!mark.reason.isEmpty)
            #expect(mark.reason.contains("commit"))
        }
    }

    @Test("A marked cell draws ink where a clean one draws none")
    func markedCellHasInk() throws {
        // Rendered rather than asserted on the string: the mark has to reach
        // the pixels through the cell that hosts it, which is what the tint
        // test covered before and is the part a refactor can silently break.
        func render(_ mark: BeadDirtyState.Mark?) throws -> RenderResult {
            let size = CGSize(width: 20, height: 24)
            let host = NSHostingView(
                rootView: AnyView(
                    DirtyMarkCell(mark: mark).frame(width: size.width, height: size.height)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return try ViewCapture.image(of: host)
        }

        let clean = try render(nil).inkCoverage()
        for mark in BeadDirtyState.Mark.allCases {
            let marked = try render(mark).inkCoverage()
            #expect(marked > clean, "\(mark) drew no more ink than a clean row")
        }
    }

    @Test("Committing changes the row fingerprint, so the gutter reloads")
    func fingerprintFollowsTheMark() async throws {
        // The bug this locks out: a commit touches no bead. `HEAD` moves and
        // every mark clears at once, so a fingerprint built from the bead
        // fields alone is identical before and after — the table never reloads
        // and the gutter keeps drawing marks for changes that are now
        // committed. Nothing else on screen would look wrong, which is what
        // makes it easy to ship.
        let store = await Fixture.loadedStore()
        defer { Task { await store.close() } }
        let rows = store.visibleIssues.prefix(3).map {
            IssueRow(issue: $0, metrics: store.metrics)
        }
        try #require(!rows.isEmpty)

        func fingerprint(marking marked: Set<Bead.ID>) -> [String] {
            let table = BeadTable(
                rows: Array(rows), specs: IssueListView.specs,
                selection: .constant([]), sort: .constant(.default),
                layout: .constant(BeadTableLayout()),
                canSort: { _ in true },
                content: { _, _ in AnyView(EmptyView()) },
                editableText: { _, row in row.issue.title },
                commitText: { _, _, _ in },
                valueMenu: { _, _ in nil },
                rowMenu: { _ in nil },
                uncommittedReason: { id in
                    marked.contains(id) ? BeadDirtyState.Mark.changed.reason : nil
                })
            return BeadTable.Coordinator(table).fingerprint(of: Array(rows))
        }

        let dirty = fingerprint(marking: [rows[0].id])
        let committed = fingerprint(marking: [])
        #expect(dirty != committed, "a commit would not have reloaded the gutter")
    }

    @Test("The gutter draws a mark in the real table after a real write")
    func markReachesTheRealTable() async throws {
        // The end-to-end shape, because this repo has shipped a table feature
        // that every unit test agreed with and that did nothing in a real
        // build: write through `br`, and require ink in that bead's gutter cell
        // of an actually-rendered `IssueListView` — the real NSTableView, the
        // real column list, the real hosted cell.
        let (store, directory) = try await Fixture.committedStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        let target = try #require(store.visibleIssues.first)
        let failed = await store.setPriority(target.priority == 0 ? 3 : 0, for: [target.id])
        #expect(failed.isEmpty, "the write failed: \(String(describing: store.loadError))")
        try #require(store.dirtyBeads.mark(for: target.id) != nil, "the write left nothing marked")

        let size = CGSize(width: 1400, height: 400)
        let host = NSHostingView(
            rootView: AnyView(
                IssueListView().environmentObject(store)
                    .frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        func tables(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let table = view as? NSTableView { found.append(table) }
            for sub in view.subviews { found += tables(in: sub) }
            return found
        }
        let table = try #require(tables(in: host).first, "the table did not render")
        let column = try #require(
            table.tableColumns.firstIndex { $0.identifier.rawValue == IssueListView.dirtyMarkID },
            "the gutter is not among the table's columns")
        let row = try #require(
            store.visibleIssues.firstIndex { $0.id == target.id }, "the bead left the list")

        // Ink coverage scoped to the one cell: the pane's own text clears any
        // whole-image threshold on its own.
        let cell = host.convert(table.frameOfCell(atColumn: column, row: row), from: table)
        let marked = try ViewCapture.image(of: host).inkCoverage(in: cell)

        // A clean row in the same table is the control, so this cannot pass on
        // a gutter that draws something for every bead.
        let cleanRow = try #require(
            store.visibleIssues.firstIndex { store.dirtyBeads.mark(for: $0.id) == nil },
            "every bead is marked; nothing to compare against")
        let cleanCell = host.convert(table.frameOfCell(atColumn: column, row: cleanRow), from: table)
        let clean = try ViewCapture.image(of: host).inkCoverage(in: cleanCell)

        #expect(marked > clean, "the marked bead's gutter is no darker than a clean one")
    }

    @Test("The marker column is the first thing on the row, and cannot be hidden")
    func markerColumnLeadsTheRow() throws {
        // A gutter is only a gutter at the edge; and it is the only surface the
        // uncommitted state has on a row now that the tint is gone, so hiding
        // it would leave the state with nowhere to appear.
        let specs = IssueListView.specs
        let first = try #require(specs.first)
        #expect(first.id == IssueListView.dirtyMarkID, "expected the mark first, got \(first.id)")
        #expect(first.isProtected)
        #expect(first.sort == nil, "an unsortable column must not claim a SortColumn")
        #expect(first.editing == nil, "the mark is derived from git; it cannot be edited")
        #expect(first.width == first.minWidth && first.width == first.maxWidth,
                "the gutter is a fixed width")
    }
}
