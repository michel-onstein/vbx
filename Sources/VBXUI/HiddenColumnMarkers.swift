import AppKit
import SwiftUI

/// Marks where columns have been hidden, and brings them back on a double-click.
///
/// Hiding a column otherwise leaves no trace: the table simply has fewer
/// columns, and nothing on screen says whether that is how it has always been
/// or something the user did last week. This draws a thicker accent rule where
/// a run of hidden columns sits between two visible ones, and double-clicking
/// that rule restores exactly that run.
///
/// ## Why this reaches into AppKit
///
/// SwiftUI's `Table` publishes no column geometry and no way to style a
/// divider, so on its public API this feature cannot be built. It is, however,
/// backed by a real `NSTableView` on macOS, and a hidden column stays in
/// `tableColumns` marked `isHidden` with its visible neighbours reporting exact
/// rects. That is enough to place the rule and hit-test it.
///
/// The cost is that this depends on an implementation detail rather than a
/// contract: a future macOS could back `Table` with something else. So it
/// **fails soft** — no table found means no markers drawn and a table that
/// still works — and `HiddenColumnMarkerTests` asserts the hierarchy is still
/// reachable, so an OS upgrade that breaks it shows up as a failing test rather
/// than a feature that quietly stopped appearing.
struct HiddenColumnMarkers: NSViewRepresentable {

    /// Changes to this trigger `updateNSView`, which is what keeps the markers
    /// in step with hiding and showing.
    ///
    /// Only its identity matters — the markers themselves are measured off the
    /// real `NSTableView`, which is the only thing that knows where the columns
    /// actually are.
    let layout: BeadTableLayout

    /// Called with the header titles of the run the user double-clicked.
    let unhide: ([String]) -> Void

    func makeNSView(context: Context) -> HiddenColumnMarkerView {
        let view = HiddenColumnMarkerView()
        view.unhide = unhide
        return view
    }

    func updateNSView(_ view: HiddenColumnMarkerView, context: Context) {
        view.unhide = unhide
        view.refresh()
    }
}

/// Draws the rules and handles the double-click.
final class HiddenColumnMarkerView: NSView {

    /// One rule: where it sits, and which columns it would bring back.
    struct Marker {
        let x: CGFloat
        let titles: [String]
    }

    /// How wide the drawn rule is, and how far either side of it counts as a
    /// hit. The rule is deliberately narrow and the target deliberately wider:
    /// a 3pt click target is unusable, and a 3pt line is what reads as a
    /// divider rather than a column.
    private static let ruleWidth: CGFloat = 3
    private static let hitSlop: CGFloat = 4

    /// The ordinary column boundary drawn below the header.
    private static let hairline: CGFloat = 1

    var unhide: (([String]) -> Void)?
    private(set) var markers: [Marker] = []

    /// How far down the accent rule runs, in this view's coordinates.
    ///
    /// The rule marks the *header* only. Running it the full height of the
    /// table turned it into a wall through the data: it competed with the rows
    /// for attention and read as a division of the content rather than a note
    /// about the columns. Below the header the boundary goes back to an
    /// ordinary hairline, like every other column edge.
    private(set) var headerHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    /// Sets the drawn state directly, for tests that need a known geometry
    /// without standing up a whole table.
    func setMarkersForTesting(_ markers: [Marker], headerHeight: CGFloat) {
        self.markers = markers
        self.headerHeight = headerHeight
        needsDisplay = true
    }

    /// Recomputes the markers from the backing table and redraws.
    func refresh() {
        let table = backingTable()
        let found = Self.markers(in: table, relativeTo: self)
        let header = Self.headerHeight(of: table, relativeTo: self)

        let unchanged =
            found.map(\.x) == markers.map(\.x)
            && found.count == markers.count
            && header == headerHeight
        guard !unchanged else { return }

        markers = found
        headerHeight = header
        needsDisplay = true
    }

    /// The bottom of the column header, in `target`'s coordinates.
    ///
    /// Measured from the table's own header view rather than assumed, because
    /// the height follows the system's control size and text settings.
    /// Returning 0 when there is no header is what makes the accent rule vanish
    /// rather than misdraw.
    static func headerHeight(of table: NSTableView?, relativeTo target: NSView) -> CGFloat {
        guard let header = table?.headerView else { return 0 }
        let rect = target.convert(header.bounds, from: header)
        return max(0, rect.maxY)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    /// The `NSTableView` behind the SwiftUI table, if it is still there.
    ///
    /// Searched from the window rather than from `self`: the overlay is a
    /// sibling of the table's host, not an ancestor of it.
    private func backingTable() -> NSTableView? {
        guard let root = window?.contentView ?? superview else { return nil }
        return Self.firstTableView(in: root)
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }

    /// Where the rules go, in `target`'s coordinates.
    ///
    /// Runs of adjacent hidden columns collapse into one marker, which is what
    /// makes a double-click restore "the group" rather than one arbitrary
    /// column of it. A run at the very start or end of the table still gets a
    /// rule, placed against the single visible neighbour it has.
    static func markers(in table: NSTableView?, relativeTo target: NSView) -> [Marker] {
        guard let table else { return [] }

        var result: [Marker] = []
        var run: [String] = []
        var leadingEdge: CGFloat?

        for (index, column) in table.tableColumns.enumerated() {
            if column.isHidden {
                run.append(column.headerCell.stringValue)
                continue
            }

            let rect = table.rect(ofColumn: index)
            if !run.isEmpty {
                // The rule sits between the last visible column before the run
                // and this one. With nothing before it, it sits on this
                // column's leading edge.
                let x = leadingEdge ?? rect.minX
                let converted = target.convert(CGPoint(x: x, y: 0), from: table)
                result.append(Marker(x: converted.x, titles: run))
                run = []
            }
            leadingEdge = rect.maxX
        }

        // A run that reaches the end of the table has no visible column after
        // it, so it hangs off the last visible edge.
        if !run.isEmpty, let trailing = leadingEdge {
            let converted = target.convert(CGPoint(x: trailing, y: 0), from: table)
            result.append(Marker(x: converted.x, titles: run))
        }

        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !markers.isEmpty else { return }

        for marker in markers {
            // The accent rule marks the header, where column controls live and
            // where the eye goes to ask about columns.
            NSColor.controlAccentColor.setFill()
            NSRect(
                x: marker.x - Self.ruleWidth / 2,
                y: 0,
                width: Self.ruleWidth,
                height: headerHeight
            ).fill()

            // Below it the boundary is an ordinary hairline, matching every
            // other column edge rather than driving a coloured wall through
            // the rows.
            guard bounds.height > headerHeight else { continue }
            NSColor.separatorColor.setFill()
            NSRect(
                x: marker.x - Self.hairline / 2,
                y: headerHeight,
                width: Self.hairline,
                height: bounds.height - headerHeight
            ).fill()
        }
    }

    /// Only the rules are clickable; everywhere else falls through to the table.
    ///
    /// Without this the overlay would swallow every click in the list — row
    /// selection, the header, the context menu — which is a far worse bug than
    /// the missing affordance it exists to add.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard marker(at: local) != nil else { return nil }
        return self
    }

    /// The rule under `point`, if the point is on one.
    ///
    /// Bounded to the header band, where the accent rule is actually drawn.
    /// Matching the full height would mean the overlay swallowed clicks on
    /// rows that happen to lie under the boundary — the row would simply not
    /// select, with nothing on screen explaining why.
    private func marker(at point: NSPoint) -> Marker? {
        guard point.y >= 0, point.y <= headerHeight else { return nil }
        return markers.first { abs($0.x - point.x) <= Self.ruleWidth / 2 + Self.hitSlop }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 2, let marker = marker(at: local) else {
            super.mouseDown(with: event)
            return
        }
        unhide?(marker.titles)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // The pointer says the rule is interactive before it is clicked, the
        // same reasoning as the bead links.
        for marker in markers {
            let band = NSRect(
                x: marker.x - Self.ruleWidth / 2 - Self.hitSlop,
                y: 0,
                width: Self.ruleWidth + Self.hitSlop * 2,
                height: headerHeight)
            addCursorRect(band, cursor: .pointingHand)
        }
    }
}
