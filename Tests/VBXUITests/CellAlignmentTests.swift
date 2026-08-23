import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Where cell content sits in its column.
///
/// A snapshot flatters this: an image of centred content and an image of
/// leading content both look like "a cell with something in it", and both pass
/// an ink-coverage check. So these measure the leftmost ink instead, which is
/// the number that tells them apart.
///
/// The bug: `HostedCell` pins its hosting view to both edges, so SwiftUI
/// content is handed the full column width — and a view given more width than
/// it needs centres in it. Every hosted column was affected (ID, P, the glyph,
/// Status, the counts, PageRank); only Title escaped, being drawn natively.
@MainActor
@Suite("Cell alignment")
struct CellAlignmentTests {

    private func hostedTable() async throws -> (NSTableView, NSView, ProjectStore) {
        let store = await Fixture.loadedStore()
        // Wide enough that every column measured below is actually on screen.
        // At 1100 the Labels column began at x=1114 once the uncommitted gutter
        // was added, and a column off the right edge draws no ink — which reads
        // as an alignment failure rather than as a viewport too narrow to hold
        // the row. It had only ~6pt of itself visible before that, so this was
        // luck rather than headroom.
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
            if let t = view as? NSTableView { found.append(t) }
            for sub in view.subviews { found += tables(in: sub) }
            return found
        }
        let table = try #require(tables(in: host).first, "the table did not render")
        return (table, host, store)
    }

    /// The leftmost ink in a cell, as a fraction of the cell's width.
    ///
    /// The whole host is captured and the cell's rect measured inside it — a
    /// cell captured on its own comes back blank.
    private func inkStart(
        _ table: NSTableView, in host: NSView, column id: String, row: Int = 0
    ) throws -> Double {
        let index = try #require(
            table.tableColumns.firstIndex { $0.identifier.rawValue == id },
            "no \(id) column")
        let cellFrame = table.frameOfCell(atColumn: index, row: row)
        let inHost = host.convert(cellFrame, from: table)
        let captured = try ViewCapture.image(of: host)
        return try #require(
            captured.firstInkFraction(in: inHost),
            "\(id) drew nothing in \(inHost)")
    }

    @Test("Hosted content starts at the leading edge, not the middle")
    func hostedContentIsLeading() async throws {
        let (table, host, store) = try await hostedTable()
        defer { Task { await store.close() } }

        // A wide column with short content — the case where centring is most
        // obvious, and the one the ID column showed.
        let id = try inkStart(table, in: host, column: SortColumn.id.rawValue)
        #expect(id < 0.25, "ID content starts \(Int(id * 100))% across its column")

        // The column this was reported for.
        let labels = try inkStart(table, in: host, column: SortColumn.labels.rawValue)
        #expect(labels < 0.25, "label pills start \(Int(labels * 100))% across their column")
    }

    @Test("The measurement can tell centred from leading")
    func measurementDiscriminates() throws {
        // Guards the assertions above. If `firstInkFraction` returned something
        // small for everything, they would pass on a broken build — which is
        // exactly how the vacuous double-click test got shipped.
        let size = CGSize(width: 200, height: 24)

        let leading = try Snapshot.render(
            Text("x").frame(maxWidth: .infinity, alignment: .leading),
            name: "align-leading", size: size)
        let centred = try Snapshot.render(
            Text("x").frame(maxWidth: .infinity, alignment: .center),
            name: "align-centred", size: size)

        let l = try #require(leading.firstInkFraction())
        let c = try #require(centred.firstInkFraction())
        #expect(l < 0.15, "leading content measured at \(l)")
        #expect(c > 0.35, "centred content measured at \(c)")
        #expect(c > l + 0.2, "the measurement does not separate the two cases")
    }

    @Test("The natively drawn Title column is unaffected")
    func titleStaysLeading() async throws {
        // Title is an `EditableCell` with an `NSTextField` pinned to the leading
        // edge — it was already correct, and the fix must not disturb it.
        let (table, host, store) = try await hostedTable()
        defer { Task { await store.close() } }
        let title = try inkStart(table, in: host, column: SortColumn.title.rawValue)
        #expect(title < 0.15, "Title content starts \(Int(title * 100))% across its column")
    }
}
