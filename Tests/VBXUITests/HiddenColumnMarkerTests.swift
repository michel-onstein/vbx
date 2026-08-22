import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// A top-left-origin container, matching how the overlay is really hosted.
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// The accent rule that shows where columns were hidden.
///
/// Serialized because every case here seeds `UserDefaults.standard` — the store
/// `@AppStorage` reads — and Swift Testing runs tests in parallel by default.
/// Two of these overlapping would each see the other's layout.
@MainActor
@Suite("Hidden column markers", .serialized)
struct HiddenColumnMarkerTests {

    private static let storageKey = "issueListLayout"

    /// Hosts the real list with `hidden` put away, and hands back the backing
    /// table alongside the overlay the markers are measured against.
    private func hostedTable(
        hiding hidden: [SortColumn]
    ) async throws -> (table: NSTableView, overlay: NSView, store: ProjectStore) {
        var layout = BeadTableLayout()
        layout.hidden = Set(hidden.map(\.rawValue))
        // `@AppStorage` persists a `RawRepresentable` as its raw value — a
        // String here, not Data. Seeding the same shape is what puts a layout
        // in front of the view before it is built.
        UserDefaults.standard.set(layout.rawValue, forKey: Self.storageKey)

        let store = await Fixture.loadedStore()
        let host = NSHostingView(
            rootView: AnyView(
                IssueListView().environmentObject(store).frame(width: 900, height: 400)))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 400)

        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(host.frame, display: true)
        host.layoutSubtreeIfNeeded()
        // The table resolves its columns on the run loop, not inside layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let table = try #require(
            Self.firstTableView(in: host),
            "no NSTableView behind SwiftUI's Table — the markers cannot be placed")
        return (table, host, store)
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }

    private func cleanUp(_ store: ProjectStore) async {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        await store.close()
    }

    @Test("The list is an NSTableView carrying every declared column")
    func backingTableIsReachable() async throws {
        // This used to be a bet on an implementation detail — the markers read
        // an `NSTableView` that SwiftUI's `Table` happened to be built on, and
        // a future macOS could have backed it with something else. `BeadTable`
        // owns the table now, so this is a contract rather than a hope.
        //
        // Still worth asserting: the markers measure column positions off this
        // table, so a column that never reaches it is a marker that never
        // appears.
        let (table, _, store) = try await hostedTable(hiding: [])
        #expect(table.tableColumns.count == IssueListView.specs.count)
        #expect(
            table.tableColumns.map(\.identifier.rawValue) == IssueListView.specs.map(\.id),
            "the table's columns are not the declared ones, in order")
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        await cleanUp(store)
    }

    @Test("A hidden column stays in the table, marked hidden")
    func hiddenColumnsRemain() async throws {
        // Not removed: the markers draw the rule showing *where* a column was
        // put away, and they find that position by walking the table's columns
        // and reading `isHidden`. A column that is gone has no position.
        let (table, _, store) = try await hostedTable(hiding: [.status])
        #expect(table.tableColumns.count == IssueListView.specs.count)
        let status = try #require(
            table.tableColumns.first { $0.identifier.rawValue == SortColumn.status.rawValue })
        #expect(status.isHidden)
        await cleanUp(store)
    }

    @Test("The identifier stays visible even if storage says to hide it")
    func idColumnCannotBeHidden() async throws {
        // The menu itself cannot be inspected headlessly — SwiftUI builds it on
        // demand when the header is right-clicked, and `headerView.menu` is nil
        // — so this asserts the invariant underneath instead. A stored layout
        // that marks `id` hidden must not actually hide it: every context menu,
        // bead link and URL is keyed by that column.
        let (table, _, store) = try await hostedTable(hiding: [.id])

        let id = try #require(table.tableColumns.first { $0.headerCell.stringValue == "ID" })
        #expect(!id.isHidden, "the identifier column was hidden")

        await cleanUp(store)
    }

    @Test("Hiding Status marks the gap between Title and Blocks")
    func hidingStatusPlacesOneMarker() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [.status])

        // A hidden column stays in tableColumns, marked hidden — that is what
        // makes the run detectable at all.
        let status = try #require(
            table.tableColumns.first { $0.headerCell.stringValue == "Status" })
        #expect(status.isHidden, "Status did not hide")

        let markers = HiddenColumnMarkerView.markers(in: table, relativeTo: overlay)
        #expect(markers.count == 1, "expected one marker, got \(markers.count)")
        #expect(markers.first?.titles == ["Status"])

        // It belongs between the two columns now adjacent, not somewhere else
        // on the row.
        let titleIndex = try #require(
            table.tableColumns.firstIndex { $0.headerCell.stringValue == "Title" })
        let blocksIndex = try #require(
            table.tableColumns.firstIndex { $0.headerCell.stringValue == "Blocks" })
        let titleRect = table.rect(ofColumn: titleIndex)
        let blocksRect = table.rect(ofColumn: blocksIndex)
        let x = try #require(markers.first?.x)
        #expect(
            x >= titleRect.maxX - 1 && x <= blocksRect.minX + 1,
            "marker at \(x) is outside \(titleRect.maxX)...\(blocksRect.minX)")

        await cleanUp(store)
    }

    @Test("Adjacent hidden columns collapse into a single marker")
    func adjacentHiddenColumnsShareAMarker() async throws {
        // The behaviour that makes "unhide the group" meaningful: two rules
        // side by side would be two clicks to undo one action.
        let (table, overlay, store) = try await hostedTable(hiding: [.blocks, .blockedBy])

        let markers = HiddenColumnMarkerView.markers(in: table, relativeTo: overlay)
        #expect(markers.count == 1, "adjacent hidden columns drew \(markers.count) markers")
        #expect(markers.first?.titles == ["Blocks", "Blocked by"])

        await cleanUp(store)
    }

    @Test("Non-adjacent hidden columns get a marker each")
    func separatedHiddenColumnsGetTheirOwnMarkers() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [.status, .labels])

        let markers = HiddenColumnMarkerView.markers(in: table, relativeTo: overlay)
        #expect(markers.count == 2, "expected two separate markers, got \(markers.count)")
        #expect(markers.map(\.titles) == [["Status"], ["Labels"]])

        await cleanUp(store)
    }

    @Test("With nothing hidden there is no rule to draw")
    func nothingHiddenDrawsNothing() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [])
        #expect(HiddenColumnMarkerView.markers(in: table, relativeTo: overlay).isEmpty)
        await cleanUp(store)
    }

    @Test("Every column title resolves back to a column")
    func titlesCoverEveryColumn() async throws {
        // The double-click restores columns by header title, so a title that
        // does not resolve is a column that can be hidden and never brought
        // back. There used to be a hand-maintained title→id map to keep in
        // step; the specs are the single declaration now, and this checks the
        // lookup `unhide(titled:)` performs against the real table's headers.
        let (table, _, store) = try await hostedTable(hiding: [])
        for column in table.tableColumns {
            let title = column.headerCell.stringValue
            // The type glyph is headerless and cannot be hidden, so it needs no
            // entry.
            guard !title.isEmpty else { continue }
            #expect(
                IssueListView.specs.contains { $0.title == title },
                "\(title) resolves to no column, so it could not be unhidden")
        }
        await cleanUp(store)
    }

    @Test("No two columns share a title")
    func titlesAreUnique() {
        // `unhide(titled:)` looks a column up by its header title, so two
        // columns sharing one would make the marker bring back the wrong one.
        let titles = IssueListView.specs.map(\.title).filter { !$0.isEmpty }
        #expect(titles.count == Set(titles).count, "duplicate column titles: \(titles)")
    }

    @Test("The overlay only intercepts clicks on a rule")
    func overlayLetsOtherClicksThrough() {
        // Without this the overlay would swallow row selection, the header and
        // the context menu — a far worse bug than the one it fixes.
        let view = HiddenColumnMarkerView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        #expect(view.hitTest(NSPoint(x: 200, y: 100)) == nil, "empty overlay captured a click")
    }

    @Test("The accent rule is the height of the header, not the whole column")
    func ruleStopsBelowTheHeader() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [.status])

        let header = HiddenColumnMarkerView.headerHeight(of: table, relativeTo: overlay)
        #expect(header > 0, "no header measured, so the rule would not draw at all")
        // Running the rule the full height turned it into a wall through the
        // rows; below the header the boundary is an ordinary hairline.
        #expect(
            header < overlay.bounds.height / 2,
            "header measured at \(header) of \(overlay.bounds.height) — that is not a header")

        await cleanUp(store)
    }

    @Test("Clicks below the header reach the rows")
    func rowsUnderTheRuleStayClickable() {
        // The rule sits in the header, so the overlay must stop intercepting
        // below it. Otherwise a row lying under the boundary would simply not
        // select, with nothing on screen explaining why.
        // Inside a parent, because `hitTest` takes a point in the *superview's*
        // coordinates — testing it detached measures the conversion rather than
        // the behaviour, and a flipped view detached inverts y.
        let parent = FlippedContainer(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let view = HiddenColumnMarkerView()
        view.frame = parent.bounds
        parent.addSubview(view)
        view.setMarkersForTesting([.init(x: 200, titles: ["Status"])], headerHeight: 28)

        #expect(view.hitTest(NSPoint(x: 200, y: 10)) === view, "the rule itself is not clickable")
        #expect(view.hitTest(NSPoint(x: 200, y: 150)) == nil, "the overlay swallowed a row click")
        #expect(view.hitTest(NSPoint(x: 50, y: 10)) == nil, "the header away from the rule was captured")
    }
}
