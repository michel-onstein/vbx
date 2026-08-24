import AppKit
import VBXCore
import SwiftUI

/// The bead list, over a real `NSTableView`.
///
/// ## Why not SwiftUI's `Table`
///
/// `Table` renders and sorts perfectly well, and it is not the reason this
/// exists. What it cannot express is **a double-click on a particular cell**.
/// Its only double-click hook is `primaryAction:`, which reports the selected
/// rows and not the column, and a gesture attached to cell content is not a
/// route to rely on — priority editing shipped that way and did nothing in a
/// real build. Editing is going to spread across columns that each need their
/// own editor, so the table has to be able to answer "which cell was hit".
///
/// `NSTableView` answers it directly, with `clickedRow` and `clickedColumn`,
/// and brings the rest of the behaviour a macOS table is expected to have —
/// a header menu for showing and hiding columns, drag-reordering, live resize,
/// and the field editor — as things that already work rather than things to
/// rebuild.
///
/// ## What is still SwiftUI
///
/// Every cell's *appearance*. Cell content is a SwiftUI view hosted in the
/// column's cell, so `StatusChip`, `LabelPill`, `MetricCell` and the rest are
/// unchanged and there is one description of how a bead looks. Only the
/// columns that accept an edit are drawn natively, because an `NSTextField` is
/// what a field editor edits.
struct BeadTable: NSViewRepresentable {
    let rows: [IssueRow]
    let specs: [BeadColumnSpec]

    @Binding var selection: Set<Issue.ID>
    @Binding var sort: SortMode
    @Binding var layout: BeadTableLayout

    /// Whether a header click on this column should be accepted. Metric
    /// columns refuse until their values exist, so the header cannot appear to
    /// sort by nothing.
    let canSort: (SortColumn) -> Bool

    /// The SwiftUI content for one cell.
    let content: (BeadColumnSpec, IssueRow) -> AnyView

    /// The title to show in an editable text cell.
    let editableText: (BeadColumnSpec, IssueRow) -> String

    /// Commit of a text edit. Returning nothing: the store reloads and the
    /// table follows.
    let commitText: (BeadColumnSpec, Issue.ID, String) -> Void

    /// The menu for a cell whose editor is a closed set of values.
    let valueMenu: (BeadColumnSpec, Set<Issue.ID>) -> NSMenu?

    /// The row context menu, for the ids AppKit's selection rules produce.
    let rowMenu: (Set<Issue.ID>) -> NSMenu?

    /// Why a row is marked as uncommitted, or nil when it is not.
    ///
    /// A reason rather than a Bool, because the mark alone says nothing: the
    /// same string becomes the row's tooltip. The mark itself is drawn by the
    /// marker column like any other cell — see ``IssueListView/dirtyMarkID``.
    let uncommittedReason: (Issue.ID) -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        table.menu = context.coordinator.makeRowMenu()

        // The header's own show/hide menu, which is the affordance a macOS
        // table is expected to have and which SwiftUI could only approximate.
        table.headerView?.menu = context.coordinator.makeHeaderMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        context.coordinator.table = table
        context.coordinator.rebuildColumns()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }

        if coordinator.columnsNeedRebuild(for: self) {
            coordinator.rebuildColumns()
        } else {
            coordinator.applyVisibility()
        }
        coordinator.applySortIndicator()

        // Reload only when the rows actually changed. `updateNSView` runs on
        // every unrelated state change in the enclosing view, and reloading
        // here unconditionally cancels an in-progress edit on every keystroke
        // elsewhere in the app.
        let fingerprint = coordinator.fingerprint(of: rows)
        if fingerprint != coordinator.lastFingerprint {
            coordinator.lastFingerprint = fingerprint
            table.reloadData()
        }
        coordinator.applySelection()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
        NSMenuDelegate, NSTextFieldDelegate
    {
        var parent: BeadTable
        weak var table: NSTableView?
        var lastFingerprint: [String] = []
        /// True while the table is changing its own selection, so the change
        /// notification does not write straight back into the binding it came
        /// from and fight the store over it.
        private var isApplyingSelection = false
        private var arranged: [BeadColumnSpec] = []

        init(_ parent: BeadTable) {
            self.parent = parent
        }

        /// Rows are identified by id plus what is drawn, so an edit that only
        /// changes a title still reloads.
        ///
        /// **The uncommitted mark is part of what is drawn.** Committing does
        /// not touch a single bead — `HEAD` moves and every mark clears at
        /// once — so a fingerprint of the bead fields alone is identical before
        /// and after, no reload happens, and the gutter keeps showing marks for
        /// changes that are now committed until something unrelated forces a
        /// redraw.
        func fingerprint(of rows: [IssueRow]) -> [String] {
            rows.map {
                let mark = parent.uncommittedReason($0.id) ?? ""
                return "\($0.id)|\($0.issue.title)|\($0.issue.priority)|\($0.issue.status.rawValue)|\(mark)"
            }
        }

        // MARK: Columns

        /// A rebuild is only needed when the *set or order* of columns
        /// changes. Hiding is applied in place, because rebuilding would
        /// discard the user's column widths along with it.
        func columnsNeedRebuild(for parent: BeadTable) -> Bool {
            var layout = parent.layout
            layout.sanitize(against: parent.specs)
            return layout.arrange(parent.specs).map(\.id) != arranged.map(\.id)
        }

        func rebuildColumns() {
            guard let table else { return }
            var layout = parent.layout
            layout.sanitize(against: parent.specs)

            for column in table.tableColumns { table.removeTableColumn(column) }
            // Every column is added, including the hidden ones, and hiding is
            // `isHidden` rather than absence. AppKit expects that — and
            // `HiddenColumnMarkers` reads `isHidden` off the real table to draw
            // the rule showing *where* a column was put away, which it cannot
            // do for a column that is not there.
            arranged = layout.arrange(parent.specs)

            for spec in arranged {
                let column = NSTableColumn(identifier: .init(spec.id))
                column.title = spec.title
                column.width = layout.widths[spec.id].map { CGFloat($0) } ?? spec.width
                column.minWidth = spec.minWidth
                column.maxWidth = spec.maxWidth
                if let sort = spec.sort {
                    // The key is the column id; the ordering itself is resolved
                    // in `sortDescriptorsDidChange`, against the store.
                    column.sortDescriptorPrototype = NSSortDescriptor(
                        key: sort.rawValue, ascending: sort.defaultAscending)
                }
                column.isHidden = layout.isHidden(spec.id)
                table.addTableColumn(column)
            }
            table.headerView?.menu = makeHeaderMenu()
            applySortIndicator()
            table.reloadData()
        }

        /// Hides and shows in place. Cheap, and it keeps column widths —
        /// a rebuild would reset them to the declared defaults every time a
        /// column was put away.
        func applyVisibility() {
            guard let table else { return }
            var layout = parent.layout
            layout.sanitize(against: parent.specs)
            for column in table.tableColumns {
                let wanted = layout.isHidden(column.identifier.rawValue)
                if column.isHidden != wanted { column.isHidden = wanted }
            }
            table.headerView?.menu = makeHeaderMenu()
        }

        func spec(for column: NSTableColumn) -> BeadColumnSpec? {
            arranged.first { $0.id == column.identifier.rawValue }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        /// The tooltip for a cell, so the mark is never the only signal.
        ///
        /// The whole row answers, not just the marker cell: the mark is a
        /// single character in a gutter, and asking the user to find it before
        /// they can learn what it means would be the same mistake as the tint
        /// it replaced.
        func tableView(
            _ tableView: NSTableView, toolTipFor cell: NSCell?, rect: NSRectPointer,
            tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint
        ) -> String {
            guard row >= 0, row < parent.rows.count else { return "" }
            return parent.uncommittedReason(parent.rows[row].id) ?? ""
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard let tableColumn, let spec = spec(for: tableColumn),
                row >= 0, row < parent.rows.count
            else { return nil }
            let beadRow = parent.rows[row]

            if spec.editing == .text {
                let identifier = NSUserInterfaceItemIdentifier("editable.\(spec.id)")
                let cell =
                    tableView.makeView(withIdentifier: identifier, owner: self) as? EditableCell
                    ?? EditableCell(identifier: identifier, delegate: self)
                cell.configure(text: parent.editableText(spec, beadRow), rowID: beadRow.id)
                return cell
            }

            let identifier = NSUserInterfaceItemIdentifier("hosted.\(spec.id)")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: self) as? HostedCell
                ?? HostedCell(identifier: identifier)
            cell.host(parent.content(spec, beadRow))
            return cell
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { index -> Issue.ID? in
                index < parent.rows.count ? parent.rows[index].id : nil
            })
            guard ids != parent.selection else { return }
            parent.selection = ids
        }

        func applySelection() {
            guard let table else { return }
            let wanted = IndexSet(
                parent.rows.enumerated()
                    .filter { parent.selection.contains($0.element.id) }
                    .map(\.offset))
            guard wanted != table.selectedRowIndexes else { return }
            isApplyingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            isApplyingSelection = false
        }

        // MARK: Sorting

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = tableView.sortDescriptors.first,
                let key = descriptor.key,
                let column = SortColumn(rawValue: key)
            else { return }
            // Refused rather than applied, so a metric with no values cannot
            // become an order with nothing on screen to explain it. The
            // indicator is put back to whatever the store still says.
            guard parent.canSort(column) else {
                applySortIndicator()
                return
            }
            parent.sort = SortMode.ordering(by: column, ascending: descriptor.ascending)
        }

        /// Draws the chevron from the store, which is the single source of the
        /// current order — the toolbar menu and bv's `s` cycle write it too.
        func applySortIndicator() {
            guard let table else { return }
            for column in table.tableColumns {
                table.setIndicatorImage(nil, in: column)
            }
            guard let current = parent.sort.column,
                let column = table.tableColumns.first(where: {
                    $0.identifier.rawValue == current.rawValue
                })
            else {
                table.sortDescriptors = []
                return
            }
            table.setIndicatorImage(
                NSImage(
                    named: parent.sort.ascending
                        ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                in: column)
            table.highlightedTableColumn = column
        }

        // MARK: Header menu

        func makeHeaderMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            var layout = parent.layout
            layout.sanitize(against: parent.specs)
            for spec in layout.arrange(parent.specs) where !spec.isProtected {
                let item = NSMenuItem(
                    title: spec.title.isEmpty ? spec.id : spec.title,
                    action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = spec.id
                item.state = layout.isHidden(spec.id) ? .off : .on
                menu.addItem(item)
            }
            return menu
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            var layout = parent.layout
            if layout.hidden.contains(id) {
                layout.hidden.remove(id)
            } else {
                layout.hidden.insert(id)
            }
            layout.sanitize(against: parent.specs)
            parent.layout = layout
        }

        // MARK: Column geometry

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn
            else { return }
            var layout = parent.layout
            layout.widths[column.identifier.rawValue] = Double(column.width)
            parent.layout = layout
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let table else { return }
            var layout = parent.layout
            // Hidden columns are in the table too, so this is the whole order.
            layout.order = table.tableColumns.map(\.identifier.rawValue)
            parent.layout = layout
        }

        // MARK: Row menu

        func makeRowMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        /// The ids a row action should act on.
        ///
        /// AppKit's rule, which the system applies everywhere: the selection
        /// when the clicked row is part of it, and just the clicked row
        /// otherwise. Reconstructing this by hand is how a context menu comes
        /// to act on something other than what is highlighted.
        func targetIDs() -> Set<Issue.ID> {
            guard let table else { return [] }
            let clicked = table.clickedRow
            guard clicked >= 0, clicked < parent.rows.count else { return parent.selection }
            let id = parent.rows[clicked].id
            return parent.selection.contains(id) ? parent.selection : [id]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0 else { return }
            guard let built = parent.rowMenu(targetIDs()) else { return }
            for item in built.items {
                built.removeItem(item)
                menu.addItem(item)
            }
        }

        // MARK: Editing

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow
            let columnIndex = table.clickedColumn
            guard row >= 0, columnIndex >= 0, columnIndex < table.tableColumns.count,
                row < parent.rows.count
            else { return }
            let column = table.tableColumns[columnIndex]
            guard let spec = spec(for: column), let editing = spec.editing else { return }

            switch editing {
            case .text:
                // The field editor, which is what makes this feel like every
                // other editable table on the system.
                table.editColumn(columnIndex, row: row, with: nil, select: true)
            case .priority:
                guard let menu = parent.valueMenu(spec, targetIDs()) else { return }
                let rect = table.frameOfCell(atColumn: columnIndex, row: row)
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: rect.minX, y: rect.maxY),
                    in: table)
            }
        }

        /// Commits a field editor.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                let cell = field.superview as? EditableCell,
                let id = cell.rowID
            else { return }
            guard let spec = arranged.first(where: { $0.editing == .text }) else { return }
            parent.commitText(spec, id, field.stringValue)
        }
    }
}

// MARK: - Cells

/// A cell whose appearance is a SwiftUI view.
///
/// Reused by `makeView(withIdentifier:)` like any AppKit cell; only the hosted
/// root view is replaced, so scrolling does not build a hosting controller per
/// row per pass.
final class HostedCell: NSTableCellView {
    private let hosting: NSHostingView<AnyView> = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hosting.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func host(_ view: AnyView) {
        // Leading, explicitly.
        //
        // The hosting view is pinned to both edges, so content is handed the
        // full column width — and a view given more width than it needs centres
        // itself in it. That put every hosted column's content in the middle of
        // its cell: ID, P, the glyph, Status, the counts, PageRank. Only Title
        // escaped, being the one column drawn natively. SwiftUI's `Table`
        // left-aligned cell content by default, so this restores what the list
        // looked like before it moved to `NSTableView`.
        //
        // Applied here rather than in each column's content, so a new column
        // cannot forget it.
        hosting.rootView = AnyView(view.frame(maxWidth: .infinity, alignment: .leading))
    }
}

/// A cell backed by a real `NSTextField`, so the field editor can edit it.
///
/// Not editable until a double-click asks for it: a table of always-editable
/// fields reads as a form, and a stray click would start an edit nobody
/// intended.
final class EditableCell: NSTableCellView {
    private(set) var rowID: Issue.ID?
    private let field = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, delegate: NSTextFieldDelegate) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = delegate
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(text: String, rowID: Issue.ID) {
        self.rowID = rowID
        field.stringValue = text
        // Left non-editable between edits; `editColumn` flips it for the
        // duration of the field editor and AppKit puts it back.
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
    }
}
