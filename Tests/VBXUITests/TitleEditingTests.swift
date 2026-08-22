import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Renaming a bead from the list.
///
/// The capability the move to `NSTableView` was for. A double-click on the
/// Title cell puts the field editor in it — which SwiftUI's `Table` could not
/// express, because its only double-click hook reports the selected rows and
/// not the column that was hit.
///
/// The click itself is not asserted here: synthesised clicks do not reach
/// content inside a table headlessly, so a test of it would pass whether or not
/// it worked. What is asserted is everything either side — the column declares
/// the editor, the cell is a real `NSTextField`, and the commit writes through
/// `br`.
@MainActor
@Suite("Title editing")
struct TitleEditingTests {

    @Test("The Title column declares a text editor")
    func titleIsEditable() throws {
        let title = try #require(
            IssueListView.specs.first { $0.id == SortColumn.title.rawValue })
        #expect(title.editing == .text)
    }

    @Test("The Title cell is a real NSTextField, which is what a field editor edits")
    func titleCellIsAField() async throws {
        let store = await Fixture.loadedStore()
        defer { Task { await store.close() } }

        let size = CGSize(width: 900, height: 300)
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
            if let t = view as? NSTableView { found.append(t) }
            for sub in view.subviews { found += tables(in: sub) }
            return found
        }
        let table = try #require(tables(in: host).first, "the table did not render")
        let columnIndex = try #require(
            table.tableColumns.firstIndex { $0.identifier.rawValue == SortColumn.title.rawValue })
        #expect(table.numberOfRows > 0)

        let cell = table.view(atColumn: columnIndex, row: 0, makeIfNecessary: true)
        let editable = try #require(cell as? EditableCell, "the Title cell is not an EditableCell")
        let field = try #require(editable.textField, "the cell has no text field")
        #expect(field.isEditable, "the field editor has nothing to edit")
        #expect(
            !field.stringValue.isEmpty,
            "the cell shows no title, so an edit would start from blank")
    }

    @Test("A rename writes through br and comes back from disk")
    func renameWrites() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try #require(store.visibleIssues.first)
        let renamed = "Renamed by a test \(UUID().uuidString.prefix(8))"

        #expect(await store.setTitle(renamed, for: target.id))
        // Read back from the store, which reloaded from what br wrote.
        #expect(store.issues.first { $0.id == target.id }?.title == renamed)
    }

    @Test("A title with characters a shell would mangle survives")
    func renameHandlesAwkwardText() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try #require(store.visibleIssues.first)
        // Nothing quotes or escapes this: the argument vector goes to `Process`
        // directly, never through a shell. If that ever changed, these are the
        // characters that would show it.
        let awkward = #"Fix "quoting" & $HOME `backticks` — 100%"#

        #expect(await store.setTitle(awkward, for: target.id))
        #expect(store.issues.first { $0.id == target.id }?.title == awkward)
    }

    @Test("An empty or unchanged title is not written")
    func pointlessRenamesAreRefused() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try #require(store.visibleIssues.first)

        // Empty: a bead with no title is unusable in every list that shows one.
        #expect(await store.setTitle("", for: target.id) == false)
        #expect(await store.setTitle("   ", for: target.id) == false)
        // Unchanged: committing a field editor the user only clicked into must
        // not produce a write, a reload and a history entry.
        #expect(await store.setTitle(target.title, for: target.id) == false)
        #expect(await store.setTitle("  \(target.title)  ", for: target.id) == false)

        #expect(store.issues.first { $0.id == target.id }?.title == target.title)
        #expect(store.loadError == nil, "a refusal must not read as a failure")
    }

    @Test("A rename is refused, not attempted, when br is missing")
    func renameNeedsBR() async throws {
        let store = await Fixture.loadedStore()
        defer { Task { await store.close() } }

        let id = try #require(store.visibleIssues.first?.id)
        struct Unreachable: Error {}
        store.writer = BeadWriter(locate: { nil }, runner: { _, _ in
            Issue.record("the runner must not be reached when br is absent")
            throw Unreachable()
        })

        #expect(await store.setTitle("anything", for: id) == false)
    }

    @Test("The command sent to br is the one br documents")
    func commandIsPinned() {
        // The flags are the contract, and a typo in one is a silent no-op or,
        // worse, a different edit. Pinned rather than mocked for the same
        // reason `priorityArguments` is.
        #expect(
            BeadWriter.titleArguments("New name", for: "vbx-1")
                == ["update", "vbx-1", "--title", "New name", "--json"])
    }
}
