import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// The bridge between the table's comparator-array sort binding and the
/// store's single sort value.
///
/// If this mapping loses anything, the header chevron and bv's `s` cycle end
/// up describing different orders — the failure the bead calls out.
@MainActor
@Suite("Column header sorting")
struct ColumnHeaderSortTests {

    @Test("Every column's comparator maps back to that same column")
    func comparatorRoundTrip() throws {
        for column in SortColumn.allCases {
            for ascending in [true, false] {
                let comparator = try #require(
                    IssueRow.comparator(for: column, ascending: ascending),
                    "no comparator for \(column)")
                #expect(IssueRow.column(of: comparator) == column, "\(column) did not round-trip")
                #expect(
                    (comparator.order == .forward) == ascending,
                    "\(column) lost its direction")
            }
        }
    }

    @Test("A row copies the engine's numbers rather than recomputing them")
    func rowCarriesEngineValues() {
        var metrics = GraphMetrics.empty
        metrics.inDegree = ["x": 4]
        metrics.outDegree = ["x": 2]
        metrics.pageRank = ["x": 0.25]

        let row = IssueRow(
            issue: Issue(id: "x", title: "Thing", status: .open, priority: 1),
            metrics: metrics)

        #expect(row.blocks == 4)
        #expect(row.blockedBy == 2)
        #expect(row.pageRank == 0.25)
        #expect(row.id == "x")
    }

    @Test("A row with no PageRank keeps it absent, not zero")
    func absentMetricStaysAbsent() {
        let row = IssueRow(
            issue: Issue(id: "x", title: "Thing", status: .open, priority: 1),
            metrics: .empty)
        // The cell renders the metric's status from this; a zero here would
        // render as a real score of 0.0000.
        #expect(row.pageRank == nil)
        // The comparator still needs a value, but it is only ever consulted
        // once the gate has let a PageRank sort through.
        #expect(row.pageRankKey == 0)
    }

    @Test("A header click drives the store's sort, and the store drives the chevron")
    func headerAndStoreAgree() async {
        let store = await Fixture.loadedStore()

        // What a click on the Title header writes.
        store.query.sort = .ordering(by: .title, ascending: true)
        #expect(store.query.sort == .titleAscending)

        // What the header chevron then reads back.
        let column = store.query.sort.column
        #expect(column == .title)
        #expect(store.query.sort.ascending)

        // And the list really is in that order.
        let titles = store.visibleIssues.map { $0.title.lowercased() }
        #expect(titles == titles.sorted())

        await store.close()
    }

    @Test("The list is ordered by whichever column the sort names")
    func listFollowsColumn() async {
        let store = await Fixture.loadedStore()

        store.query.sort = .ordering(by: .id, ascending: true)
        let ascending = store.visibleIssues.map(\Bead.id)
        store.query.sort = .ordering(by: .id, ascending: false)
        let descending = store.visibleIssues.map(\Bead.id)

        #expect(ascending == ascending.sorted())
        #expect(descending == ascending.reversed())

        await store.close()
    }

    @Test("The issue list renders with a column sort applied")
    func rendersSortedList() async throws {
        let store = await Fixture.loadedStore()
        store.query.sort = .ordering(by: .blocks, ascending: false)

        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "list-sorted-by-blocks",
            size: CGSize(width: 1100, height: 600)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }
}

/// The columns the table is built from.
///
/// These used to be read out of `IssueListView.swift` as text, because SwiftUI's
/// `Table` built its columns from a result builder and exposed no list to
/// inspect. Parsing source for `TableColumn("…")` was the only way to pin the
/// order, and it silently matched nothing the moment the table changed shape —
/// which is exactly what happened when the list moved to `NSTableView`.
///
/// `IssueListView.specs` is that list, as a value. Every assertion below is now
/// about the thing the app actually uses.
@MainActor
@Suite("Table columns")
struct TableColumnOrderTests {

    private var specs: [BeadColumnSpec] { IssueListView.specs }

    @Test("Priority is the column immediately after ID")
    func priorityFollowsID() throws {
        let ids = specs.map(\.id)
        let id = try #require(ids.firstIndex(of: SortColumn.id.rawValue), "no ID column")
        #expect(id == 1, "the mark gutter is the only thing before ID; got \(ids)")
        let priority = try #require(
            ids.firstIndex(of: SortColumn.priority.rawValue), "no priority column")
        #expect(priority == id + 1, "priority must follow ID directly; got \(ids)")
    }

    @Test("The columns the view is built from are all present")
    func columnsPresent() {
        let titles = specs.map(\.title)
        for expected in ["ID", "P", "Title", "Status", "Labels", "Updated"] {
            #expect(titles.contains(expected), "\(expected) column missing from \(titles)")
        }
        #expect(specs.count >= 10, "too few columns: \(titles)")
    }

    @Test("No two columns share an identifier")
    func idsAreUnique() {
        // The bug this caught in review: PageRank was given the `blocks`
        // identifier, so hiding one would have acted on the other and both
        // would have shared a saved width.
        let ids = specs.map(\.id)
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty, "duplicated identifiers: \(duplicates.keys.sorted())")
    }

    @Test("Identifiers come from SortColumn rather than being written out twice")
    func idsAreDerivedFromSortColumn() {
        // The rule is about *sortable* columns: a hand-written identifier on
        // one of those would break the chevron, which is asserted separately.
        // A column that does not sort has no `SortColumn` to take an identifier
        // from and must supply its own — the type glyph and the combined
        // Blocked/by column are both in that position.
        //
        // Stated this way rather than as a list of allowed names, so adding
        // another unsortable column does not mean editing this test to keep it
        // passing — which is how an assertion stops meaning anything.
        for spec in specs where spec.sort != nil {
            #expect(
                SortColumn(rawValue: spec.id) != nil,
                "\(spec.title) sorts but its identifier \(spec.id) is hand-written")
        }
        let unsortable = specs.filter { $0.sort == nil }.map(\.id)
        #expect(
            unsortable.sorted() == ["blockedRatio", "dirtyMark", "type"],
            "unexpected unsortable columns \(unsortable)")
    }

    @Test("A sortable column's identifier is its SortColumn's raw value")
    func sortableIDsMatchTheirColumn() {
        // Load-bearing, and easy to break by hand. The sort descriptor's key is
        // the `SortColumn` raw value, while the indicator is drawn on the
        // `NSTableColumn` whose *identifier* matches the store's current
        // column. If the two ever disagreed, clicking a header would reorder
        // the list and put the chevron somewhere else — or nowhere.
        for spec in specs {
            guard let sort = spec.sort else { continue }
            #expect(
                spec.id == sort.rawValue,
                "\(spec.title): identifier \(spec.id) but sorts by \(sort.rawValue)")
        }
    }

    @Test("The identifier and the type glyph cannot be hidden")
    func essentialColumnsAreNotHideable() {
        // Every bead link, context menu and URL is keyed by the id; the glyph
        // column is headerless and would list as a blank menu row; the
        // uncommitted gutter is the only place a row says it is ahead of the
        // last commit, so hiding it would leave that state invisible. All three
        // are deliberately exempt, and a later tidy-up must not quietly
        // re-enable them.
        let protected = specs.filter(\.isProtected).map(\.id)
        #expect(
            protected.sorted()
                == [SortColumn.id.rawValue, "type", IssueListView.dirtyMarkID].sorted(),
            "expected exactly ID, the type glyph and the mark gutter, got \(protected)")
    }

    @Test("Only columns that can be edited declare an editor")
    func editorsAreDeclaredWhereExpected() {
        // The point of the NSTableView move: a double-click has to reach a
        // particular cell. Both editors are asserted so that removing one is a
        // deliberate act rather than a quiet regression.
        let editable = specs.compactMap { spec -> String? in
            spec.editing == nil ? nil : spec.id
        }
        #expect(
            editable.sorted() == [SortColumn.priority.rawValue, SortColumn.title.rawValue].sorted(),
            "unexpected editable columns: \(editable)")
    }

    @Test("Every column has a usable width range")
    func widthsAreSane() {
        for spec in specs {
            #expect(spec.minWidth <= spec.width, "\(spec.id): width below its minimum")
            #expect(spec.width <= spec.maxWidth, "\(spec.id): width above its maximum")
            #expect(spec.minWidth > 0, "\(spec.id): zero minimum width")
        }
    }
}
