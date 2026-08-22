import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The column that shows both dependency counts at once.
@MainActor
@Suite("Blocked/by column")
struct BlockedRatioColumnTests {

    @Test("Both counts read as one value")
    func formatsBothCounts() {
        #expect(IssueRow.blockedSummary(blocks: 7, blockedBy: 1) == "7 / 1")
        #expect(IssueRow.blockedSummary(blocks: 12, blockedBy: 30) == "12 / 30")
    }

    @Test("A zero side reads the way the single-value columns write it")
    func zeroMatchesTheOtherColumns() {
        // Consistency is the point: "Blocks: —" beside "Blocked/by: 0 / 2"
        // would read as two different facts about the same number.
        #expect(IssueRow.countLabel(0) == "—")
        #expect(IssueRow.countLabel(3) == "3")
        #expect(IssueRow.blockedSummary(blocks: 0, blockedBy: 2) == "— / 2")
        #expect(IssueRow.blockedSummary(blocks: 5, blockedBy: 0) == "5 / —")
        #expect(IssueRow.blockedSummary(blocks: 0, blockedBy: 0) == "— / —")
    }

    @Test("The column exists beside the two it summarises, not instead of them")
    func allThreeColumnsExist() throws {
        let ids = IssueListView.specs.map(\.id)
        #expect(ids.contains(SortColumn.blocks.rawValue))
        #expect(ids.contains(SortColumn.blockedBy.rawValue))
        #expect(ids.contains(IssueListView.blockedRatioID))

        let spec = try #require(
            IssueListView.specs.first { $0.id == IssueListView.blockedRatioID })
        #expect(spec.title == "Blocked/by")
        // Unsortable on purpose — see the spec's own comment. If someone gives
        // it a `SortColumn`, the identifier rule in `Table columns` applies and
        // this should be revisited rather than silently satisfied.
        #expect(spec.sort == nil)
        #expect(spec.editing == nil)
    }

    @Test("It sits next to the columns it combines")
    func placedBesideItsSources() throws {
        // Not a cosmetic preference: the point of the column is comparing it
        // with its two sources, and the hidden-column markers read runs of
        // adjacent columns.
        let ids = IssueListView.specs.map(\.id)
        let blockedBy = try #require(ids.firstIndex(of: SortColumn.blockedBy.rawValue))
        let combined = try #require(ids.firstIndex(of: IssueListView.blockedRatioID))
        #expect(combined == blockedBy + 1, "expected it directly after Blocked by; got \(ids)")
    }

    @Test("The column renders in the real table")
    func rendersInTheTable() async throws {
        let store = await Fixture.loadedStore()
        defer { Task { await store.close() } }

        let size = CGSize(width: 1200, height: 320)
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
        let table = try #require(tables(in: host).first)
        let index = try #require(
            table.tableColumns.firstIndex {
                $0.identifier.rawValue == IssueListView.blockedRatioID
            },
            "the column never reached the table")
        #expect(table.tableColumns[index].title == "Blocked/by")

        // And it draws something: the cell is hosted content, which is exactly
        // what silently renders blank if a case is missing from the switch.
        let cellFrame = table.frameOfCell(atColumn: index, row: 0)
        let captured = try ViewCapture.image(of: host)
        #expect(
            captured.inkCoverage(in: host.convert(cellFrame, from: table)) > 0.01,
            "the Blocked/by cell drew nothing")
    }
}
