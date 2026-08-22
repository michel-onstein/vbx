import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Editing a bead's priority, and the list surviving a scroll.
///
/// The scroll case is a regression guard with teeth: a cell that reads its
/// store from the environment resolves for the rows on screen at first layout
/// and *traps* on the first row created after it, because
/// `EnvironmentObject.error()` is a `fatalError`. It only ever showed up on a
/// workspace with more beads than fit in the window, never on vbx's own. The
/// store is handed to cell content directly now, and the test takes the
/// process down rather than failing if that ever changes.
@MainActor
@Suite("Priority editing")
struct PriorityCellTests {

    /// Every scroll view under `view`, depth first.
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    @Test("Scrolling the list past the first screen of rows does not trap")
    func scrollingTheListCreatesCellsThatKeepTheirStore() async throws {
        let store = await Fixture.loadedStore()

        // Short on purpose: the bug needs rows that are *not* laid out on the
        // first pass, so the window has to be smaller than the table's content.
        let size = CGSize(width: 1000, height: 220)
        #expect(
            store.visibleIssues.count > 8,
            "the fixture must overflow a \(Int(size.height))pt window or this proves nothing")

        let root = IssueListView()
            .environmentObject(store)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(host.frame, display: true)
        host.layoutSubtreeIfNeeded()
        // The table resolves its rows on the run loop, not inside layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let scrolls = scrollViews(in: host)
        #expect(!scrolls.isEmpty, "no scroll view found — the table did not render")

        // Walk well past the content height so rows are built, released and
        // built again, which is what the running app does under a flick.
        for offset in stride(from: 0.0, through: 900.0, by: 40.0) {
            for scroll in scrolls {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - The edit path
    //
    // Reported from a real build: "the editing of Priority is not in this
    // build". It was in the build and could not be reached — `br` was found and
    // `canEditBeads` was true, so the write path was open and the double-click
    // on the cell was what failed.
    //
    // The list is an `NSTableView` now, which answers "which cell was hit" with
    // `clickedRow` and `clickedColumn`, so the double-click reaches the column
    // that was actually clicked. The context menu carries the same action for
    // a selection of any size.

    @Test("Editing is available: br is found and nothing blocks a write")
    func editingIsAvailable() async {
        let store = await Fixture.loadedStore()
        // This is what ruled out the obvious explanation. If it ever fails,
        // the cause is the environment, not the UI.
        #expect(store.writer.isAvailable, "br was not found: \(String(describing: BeadWriter.locateBR()))")
        #expect(store.canEditBeads)
        #expect(store.editingUnavailableReason == nil)
    }

    // There is still no test asserting that a double-click *opens* the editor.
    //
    // One was written against the SwiftUI table and removed as vacuous: it
    // synthesised a double-click, asserted no popover appeared, and would have
    // passed either way, because synthesised clicks do not reach content inside
    // a table headlessly. That has not changed with `NSTableView`, so the same
    // test would be no better now.
    //
    // What is testable is on both sides of the click, and is: the columns that
    // declare an editor (`Table columns`), and the write each editor performs
    // (below).

    @Test("Setting a priority on several beads writes each one")
    func setPriorityAcrossASelection() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let targets = Array(store.visibleIssues.prefix(2))
        try #require(targets.count == 2, "the fixture needs two beads")
        let ids = Set(targets.map(\.id))
        // Something none of them already is, or a no-op would look like success.
        let target = (0...4).first { value in
            !targets.contains { $0.priority == value }
        }
        let wanted = try #require(target)

        let failed = await store.setPriority(wanted, for: ids)
        #expect(failed.isEmpty, "could not write: \(failed) — \(String(describing: store.loadError))")

        // Read back from the store, which reloaded from what br wrote.
        for id in ids {
            let issue = store.issues.first { $0.id == id }
            #expect(issue?.priority == wanted, "\(id) is \(String(describing: issue?.priority))")
        }
    }

    @Test("A refused edit reports rather than failing silently")
    func refusedEditIsReported() async throws {
        let store = await Fixture.loadedStore()
        // Time travel is the state the store already refuses in; using it keeps
        // this honest about the real guard rather than mocking one.
        let id = try #require(store.visibleIssues.first?.id)
        struct Unreachable: Error {}
        store.writer = BeadWriter(locate: { nil }, runner: { _, _ in
            // Refusing happens before any process is spawned; reaching this
            // would mean the guard had stopped guarding.
            Issue.record("the runner must not be reached when br is absent")
            throw Unreachable()
        })
        #expect(!store.canEditBeads)
        #expect(store.editingUnavailableReason == "Install br to edit beads from vbx.")

        let failed = await store.setPriority(0, for: [id])
        #expect(failed == [id], "a refused write must report the ids it did not apply")
    }
}
