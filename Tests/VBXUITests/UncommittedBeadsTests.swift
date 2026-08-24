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
                editRefusal: { _ in nil },
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

    @Test("The glyph still fits once the gutter is halved")
    func markIsNotClipped() throws {
        // The failure this column is most likely to ship: 10pt of column less
        // two 1pt insets is 8pt to draw a monospaced callout character in, and
        // a glyph clipped to a sliver still passes "there is ink here". So the
        // same mark is rendered in the real content width and in a generous
        // one, and required to put the same amount of ink on screen.
        let spec = try #require(
            IssueListView.specs.first { $0.id == IssueListView.dirtyMarkID })
        let content = spec.width - spec.contentInset * 2

        func ink(width: CGFloat) throws -> Double {
            let size = CGSize(width: 60, height: 24)
            let host = NSHostingView(
                rootView: AnyView(
                    DirtyMarkCell(mark: .changed)
                        .frame(width: width, alignment: .trailing)
                        .frame(width: size.width, height: size.height, alignment: .trailing)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return try ViewCapture.image(of: host).inkCoverage()
        }

        let tight = try ink(width: content)
        let roomy = try ink(width: 60)
        #expect(tight > 0, "the glyph drew nothing at \(content)pt")
        #expect(
            tight >= roomy * 0.9,
            "the glyph is clipped at \(content)pt: \(tight) ink against \(roomy)")
    }

    @Test("The mark sits next to the ID, and cannot reach it")
    func markSitsBesideTheID() async throws {
        // Halving the column moved the glyph 10pt and no further, because what
        // actually separates it from the id is the table's own
        // `intercellSpacing` — 17pt on an inset-style table, between every pair
        // of columns and therefore not narrowable for one of them. The mark
        // overhangs into that gap instead.
        //
        // Two halves, and the second is why the overhang is safe: it draws over
        // spacing that belongs to no column, and it must not be long enough to
        // reach the column beyond.
        let (store, directory) = try await Fixture.committedStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let target = try #require(store.visibleIssues.first)
        _ = await store.setPriority(target.priority == 0 ? 3 : 0, for: [target.id])
        try #require(store.dirtyBeads.mark(for: target.id) != nil, "nothing was marked")

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
        let row = try #require(store.visibleIssues.firstIndex { $0.id == target.id })
        let gutter = table.frameOfCell(atColumn: 0, row: row)
        let idCell = table.frameOfCell(atColumn: 1, row: row)

        // Two zones in the space before the id: the gap the mark should now sit
        // in, and everything before it, where it used to sit. Stated as "which
        // zone holds the ink" rather than "how far across the ink starts",
        // because the second is sensitive to the row stripe and to whatever the
        // table has managed to draw so far — it passed alone and failed in the
        // parallel suite.
        func zones() throws -> (near: Double, far: Double) {
            let image = try ViewCapture.image(of: host)
            let nearRect = CGRect(
                x: idCell.minX - 14, y: gutter.minY, width: 14, height: gutter.height)
            // From the gutter cell, not from x=0: everything left of it is
            // outside the row, and the step from the window's background to the
            // row's counts as ink — which is what made this fail in the
            // parallel suite while passing alone.
            let farRect = CGRect(
                x: gutter.minX, y: gutter.minY,
                width: idCell.minX - 14 - gutter.minX, height: gutter.height)
            return (
                image.inkCoverage(in: host.convert(nearRect, from: table)),
                image.inkCoverage(in: host.convert(farRect, from: table)))
        }

        // Waited for rather than assumed: under a loaded parallel suite the
        // table needs longer than a fixed pause to draw a state that arrives
        // asynchronously.
        var measured = try zones()
        for _ in 0..<20 where measured.near == 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            measured = try zones()
        }

        #expect(
            measured.near > 0,
            "the mark drew nothing in the 14pt before the id")
        // Several times, not "none at all": a rendered row leaves a few
        // antialiased pixels at a zone boundary, and demanding exactly zero
        // fails on those rather than on the mark being in the wrong place.
        #expect(
            measured.near > measured.far * 3,
            "the mark is still a gap away from the id (near \(measured.near), far \(measured.far))")

        // And it stops short of the id: an overhang as long as the spacing
        // would draw over the next column's content rather than over the gap.
        let spec = try #require(
            IssueListView.specs.first { $0.id == IssueListView.dirtyMarkID })
        let overhang = -spec.contentTrailingInset
        #expect(overhang > 0, "the mark no longer overhangs; it will sit a gap away from the id")
        #expect(
            overhang < table.intercellSpacing.width,
            "an overhang of \(overhang) reaches past the \(table.intercellSpacing.width)pt gap into the id column")
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
        #expect(first.contentAlignment == .trailing,
                "the mark belongs against the ID beside it")
    }
}
