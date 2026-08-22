import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Hiding columns, and the layout surviving a relaunch.
///
/// The persistence half cannot be checked by looking at the screen: it either
/// survives the round trip `@AppStorage` performs, or the user's layout
/// silently resets on the next launch and nothing in the UI says so.
///
/// These moved from `TableColumnCustomization` to ``BeadTableLayout`` when the
/// list moved to `NSTableView`. The old tests exercised a SwiftUI type the app
/// no longer stores, which would have kept passing while the real layout broke.
@MainActor
@Suite("Column visibility")
struct ColumnVisibilityTests {

    @Test("A hidden column survives the round trip @AppStorage performs")
    func hiddenColumnPersists() throws {
        var layout = BeadTableLayout()
        layout.hidden = [SortColumn.pageRank.rawValue, SortColumn.blockedBy.rawValue]
        layout.widths[SortColumn.title.rawValue] = 412
        layout.order = IssueListView.specs.map(\.id).reversed()

        // `@AppStorage` persists this through `RawRepresentable`, so that — not
        // `Codable` in the abstract — is the trip a relaunch actually makes.
        let restored = try #require(BeadTableLayout(rawValue: layout.rawValue))

        #expect(restored.isHidden(SortColumn.pageRank.rawValue))
        #expect(restored.isHidden(SortColumn.blockedBy.rawValue))
        // A column never touched must not come back hidden.
        #expect(!restored.isHidden(SortColumn.title.rawValue))
        #expect(restored.widths[SortColumn.title.rawValue] == 412)
        #expect(restored.order == layout.order)
    }

    @Test("An unreadable stored layout falls back rather than failing")
    func corruptLayoutIsIgnored() {
        // A default layout is a perfectly good table, so a stored value that
        // cannot be decoded must not be worth failing over.
        #expect(BeadTableLayout(rawValue: "not json") == nil)
        #expect(BeadTableLayout(rawValue: "") == nil)
    }

    @Test("An untouched layout hides nothing")
    func defaultLayoutShowsEverything() {
        // First launch: every column visible. A default that hid anything
        // would look like data loss to someone who had never opened the menu.
        let layout = BeadTableLayout()
        for spec in IssueListView.specs {
            #expect(!layout.isHidden(spec.id), "\(spec.id) starts hidden")
        }
    }

    @Test("Protected columns cannot be hidden, whatever the stored layout says")
    func protectedColumnsAreForcedVisible() {
        // Leaving them out of the header menu does not enforce anything — a
        // stored layout marking them hidden still hid them in the SwiftUI
        // version until it sanitised the same way. The menu entry and the
        // enforcement are separate problems.
        var layout = BeadTableLayout()
        layout.hidden = Set(IssueListView.specs.map(\.id))
        layout.sanitize(against: IssueListView.specs)

        for spec in IssueListView.specs where spec.isProtected {
            #expect(!layout.isHidden(spec.id), "\(spec.id) is protected but was hidden")
        }
        // And the rest really are hidden, or this would pass by hiding nothing.
        #expect(IssueListView.specs.contains { !$0.isProtected && layout.isHidden($0.id) })
    }

    @Test("An unknown column in a stored layout is dropped, a new one is kept")
    func layoutSurvivesAChangedColumnSet() {
        // Both halves matter: an id in the stored order that no longer exists
        // is a column that was removed, and a spec missing from the order is
        // one added since the layout was written.
        var layout = BeadTableLayout()
        layout.order = ["gone", SortColumn.title.rawValue]
        layout.hidden = ["gone"]
        layout.widths = ["gone": 100]
        layout.sanitize(against: IssueListView.specs)

        #expect(!layout.order.contains("gone"))
        #expect(!layout.hidden.contains("gone"))
        #expect(layout.widths["gone"] == nil)

        let arranged = layout.arrange(IssueListView.specs)
        #expect(arranged.first?.id == SortColumn.title.rawValue, "stored order ignored")
        #expect(
            Set(arranged.map(\.id)) == Set(IssueListView.specs.map(\.id)),
            "a column was lost or invented")
    }

    @Test("The list still renders with columns hidden")
    func listRendersWithHiddenColumns() async throws {
        let store = await Fixture.loadedStore()

        // The store drives the rows; the layout is view state, so this is a
        // check that the table still draws rather than that the columns are
        // gone — `@AppStorage` is not injectable from here.
        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "issue-list-hidden-columns",
            size: CGSize(width: 700, height: 420)
        )
        #expect(result.inkCoverage() > 0.015, "list looks blank (ink \(result.inkCoverage()))")

        await store.close()
    }
}
