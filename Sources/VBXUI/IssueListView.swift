import AppKit
import VBXAppCore
import VBXCore
import SwiftUI

/// Native sortable table, over `NSTableView`. Metric columns render a
/// placeholder rather than a zero until Phase 2 lands.
///
/// Sorting is driven from ``ProjectStore/query``'s single `sort` value rather
/// than from table-local state. The toolbar menu, bv's `s` cycle and a header
/// click all write that one value, so the header chevron and the cycle can
/// never disagree about the current order.
///
/// The table itself is ``BeadTable`` — see there for why this is not SwiftUI's
/// `Table`. What stayed SwiftUI is every cell's appearance: the column content
/// below is the same set of views as before.
struct IssueListView: View {
    @EnvironmentObject var store: ProjectStore

    /// Which columns are on screen, in what order, at what width.
    ///
    /// The key is a persistence contract: it holds users' saved layouts, so it
    /// must not be renamed casually. It is a *new* key — the previous one held
    /// a `TableColumnCustomization`, a SwiftUI type that cannot describe this
    /// table — so a layout saved before this change is ignored and the columns
    /// come back at their defaults, once.
    @AppStorage("issueListLayout")
    private var layout = BeadTableLayout()

    /// Every column, declared once.
    ///
    /// Previously a column was declared three times — the `TableColumn`, its
    /// `customizationID`, and a title→id map the hidden-column markers read —
    /// with a test whose whole job was catching those drift apart. One value
    /// each now, and that test is unnecessary.
    static let specs: [BeadColumnSpec] = [
        BeadColumnSpec(
            id: SortColumn.id.rawValue, title: "ID", sort: .id,
            width: 96, minWidth: 70, maxWidth: 160, isProtected: true),
        BeadColumnSpec(
            id: SortColumn.priority.rawValue, title: "P", sort: .priority,
            width: 30, minWidth: 30, maxWidth: 44, editing: .priority),
        BeadColumnSpec(
            id: "type", title: "", width: 22, minWidth: 22, maxWidth: 22, isProtected: true),
        BeadColumnSpec(
            id: SortColumn.title.rawValue, title: "Title", sort: .title,
            width: 360, minWidth: 200, maxWidth: 4000, editing: .text),
        BeadColumnSpec(
            id: SortColumn.status.rawValue, title: "Status", sort: .status,
            width: 110, minWidth: 90, maxWidth: 140),
        BeadColumnSpec(
            id: SortColumn.blocks.rawValue, title: "Blocks", sort: .blocks,
            width: 52, minWidth: 52, maxWidth: 80),
        BeadColumnSpec(
            id: SortColumn.blockedBy.rawValue, title: "Blocked by", sort: .blockedBy,
            width: 74, minWidth: 74, maxWidth: 110),
        // Both counts in one column, for scanning. It sits beside the two it
        // summarises rather than replacing them: someone who wants one dense
        // column hides the other two from the header menu, and someone who
        // wants to sort by each separately still can.
        //
        // Deliberately unsortable. A sortable column's identifier must equal
        // its `SortColumn` raw value, so sorting here would need a new
        // `SortColumn` case *and* a definition of what the order is — by
        // blocks, by blocked-by, or by the two summed. None of those is
        // obviously right, and the two single-value columns already carry
        // sorting. Add a case if someone actually wants one.
        BeadColumnSpec(
            id: Self.blockedRatioID, title: "Blocked/by",
            width: 78, minWidth: 66, maxWidth: 120),
        BeadColumnSpec(
            id: SortColumn.pageRank.rawValue, title: "PageRank", sort: .pageRank,
            width: 86, minWidth: 76, maxWidth: 120),
        BeadColumnSpec(
            id: SortColumn.labels.rawValue, title: "Labels", sort: .labels,
            width: 140, minWidth: 80, maxWidth: 4000),
        BeadColumnSpec(
            id: SortColumn.created.rawValue, title: "Created", sort: .created,
            width: 100, minWidth: 80, maxWidth: 140),
        BeadColumnSpec(
            id: SortColumn.updated.rawValue, title: "Updated", sort: .updated,
            width: 100, minWidth: 80, maxWidth: 140),
    ]

    /// bv's range. Beyond P4 is backlog, and `br` rejects it.
    static let priorities = 0...4

    /// The combined blocks / blocked-by column.
    ///
    /// Not a `SortColumn` raw value, because it does not sort — the only other
    /// column in that position is the type glyph.
    static let blockedRatioID = "blockedRatio"

    /// The columns the user has put away.
    private var hiddenColumns: Set<SortColumn> {
        Set(Self.specs.compactMap { spec in
            layout.isHidden(spec.id) ? spec.sort : nil
        })
    }

    private var rows: [IssueRow] {
        let metrics = store.metrics
        return store.visibleIssues.map { IssueRow(issue: $0, metrics: metrics) }
    }

    var body: some View {
        BeadTable(
            rows: rows,
            specs: Self.specs,
            selection: $store.selection,
            sort: $store.query.sort,
            layout: $layout,
            // Refused rather than applied, so a metric with no values cannot
            // become an order with nothing on screen to explain it.
            canSort: { column in
                !(column.requiresPhase2 && !store.metrics.hasPhase2Values)
            },
            content: { spec, row in cellContent(spec, row) },
            editableText: { _, row in row.issue.title },
            commitText: { _, id, text in
                Task { await store.setTitle(text, for: id) }
            },
            valueMenu: { spec, ids in priorityMenu(spec, ids) },
            rowMenu: { ids in rowMenu(for: ids) },
            uncommittedReason: { id in store.dirtyBeads.reason(for: id) }
        )
        // Shows where columns were hidden, and brings them back on a
        // double-click. Drawn over the table because a styled divider is not
        // something a table gives you — see HiddenColumnMarkers.
        .overlay {
            HiddenColumnMarkers(layout: layout) { titles in
                unhide(titled: titles)
            }
        }
        // Hiding the column being sorted by would otherwise leave the list in
        // an order with nothing on screen to explain it: the header carrying
        // the chevron is the thing that just disappeared.
        .onChange(of: layout) {
            store.query.sort = store.query.sort.whenColumnsHidden(hiddenColumns)
        }
        .overlay {
            if store.visibleIssues.isEmpty {
                EmptyStateView(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No matching beads",
                    message: store.query.searchText.isEmpty
                        ? "No beads match the \(store.query.filter.displayName.lowercased()) filter."
                        : "No beads match “\(store.query.searchText)”."
                )
            }
        }
    }

    /// Brings back the run of columns behind one marker.
    private func unhide(titled titles: [String]) {
        var updated = layout
        for title in titles {
            guard let spec = Self.specs.first(where: { $0.title == title }) else { continue }
            updated.hidden.remove(spec.id)
        }
        layout = updated
    }

    // MARK: - Cell content
    //
    // Unchanged from the SwiftUI table: these are the same views, hosted in
    // the column's cell. The store is captured here rather than read from the
    // environment — a cell's subgraph does not inherit one, which is what
    // crashed the list on scroll before `PriorityCell` was handed its store.

    @ViewBuilder
    private func cell(_ spec: BeadColumnSpec, _ row: IssueRow) -> some View {
        switch spec.id {
        case SortColumn.id.rawValue:
            Text(row.issue.id).monospaced().font(.callout)

        case SortColumn.priority.rawValue:
            Text(row.issue.priorityLabel)
                .monospacedDigit()
                .foregroundStyle(row.issue.priority <= 1 ? .primary : .secondary)
                .help(
                    store.editingUnavailableReason
                        ?? "Double-click to change the priority")

        case "type":
            Image(systemName: row.issue.type.symbolName)
                .foregroundStyle(.secondary)
                .help(row.issue.type.displayName)

        case SortColumn.status.rawValue:
            StatusChip(status: row.issue.status)

        case SortColumn.blocks.rawValue:
            Text(IssueRow.countLabel(row.blocks))
                .monospacedDigit()
                .foregroundStyle(row.blocks > 0 ? .primary : .tertiary)
                .help("Issues that depend on this one")

        case SortColumn.blockedBy.rawValue:
            Text(IssueRow.countLabel(row.blockedBy))
                .monospacedDigit()
                .foregroundStyle(row.blockedBy > 0 ? .primary : .tertiary)

        case Self.blockedRatioID:
            // Three pieces rather than one string, so each side keeps the
            // de-emphasis the single-value columns give a zero. The digits come
            // from the same helper the tooltip and the tests read, so the two
            // cannot drift.
            HStack(spacing: 3) {
                Text(IssueRow.countLabel(row.blocks))
                    .foregroundStyle(row.blocks > 0 ? .primary : .tertiary)
                Text("/").foregroundStyle(.quaternary)
                Text(IssueRow.countLabel(row.blockedBy))
                    .foregroundStyle(row.blockedBy > 0 ? .primary : .tertiary)
            }
            .monospacedDigit()
            .help("Issues that depend on this one / issues it waits for")

        case SortColumn.pageRank.rawValue:
            MetricCell(
                value: row.pageRank,
                status: store.metrics.status?.pageRank,
                format: { String(format: "%.4f", $0) })

        case SortColumn.labels.rawValue:
            // Identity is the position, not the label: a bead carrying the
            // same label twice is bad data, but it must not collide here and
            // drop one of the pills.
            HStack(spacing: 4) {
                ForEach(Array(row.issue.labels.enumerated()), id: \.offset) { _, label in
                    LabelPill(label: label, isFiltered: store.query.labels.contains(label))
                        .onTapGesture(count: 2) { store.toggleLabelFilter(label) }
                }
            }
            .help(row.issue.labels.joined(separator: ", "))

        case SortColumn.created.rawValue:
            Text(
                row.issue.createdAt.map {
                    Self.relative.localizedString(for: $0, relativeTo: .now)
                } ?? "—"
            )
            .foregroundStyle(.secondary)

        case SortColumn.updated.rawValue:
            Text(
                row.issue.updatedAt.map {
                    Self.relative.localizedString(for: $0, relativeTo: .now)
                } ?? "—"
            )
            .foregroundStyle(.secondary)

        default:
            EmptyView()
        }
    }

    /// The Title cell's *display* form. The column is edited natively, so this
    /// is only what is drawn when no editor is open — but the badges are the
    /// reason the row is interesting while time travelling, so they stay.
    @ViewBuilder
    private func titleCell(_ row: IssueRow) -> some View {
        HStack(spacing: 6) {
            if let badge = store.badge(for: row.id) {
                DiffBadgeView(badge: badge)
            }
            if let repo = store.repo(of: row.id) {
                RepoBadge(repo: repo, isCrossRepo: store.isCrossRepo(row.id))
            }
            Text(row.issue.title).lineLimit(1)
            if store.actionable.contains(row.id) {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Actionable now")
            }
        }
    }

    private func cellContent(_ spec: BeadColumnSpec, _ row: IssueRow) -> AnyView {
        if spec.id == SortColumn.title.rawValue {
            return AnyView(titleCell(row))
        }
        return AnyView(cell(spec, row))
    }

    // MARK: - Menus

    /// The priority editor: a menu at the cell, for a closed set of values.
    private func priorityMenu(_ spec: BeadColumnSpec, _ ids: Set<Issue.ID>) -> NSMenu? {
        guard !ids.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let reason = store.editingUnavailableReason {
            // A disabled menu with no explanation is the state this app
            // deliberately avoids elsewhere; say why rather than just refuse.
            let item = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        // A checkmark only when every selected bead already agrees; a mixed
        // selection has no single current value to tick.
        let current = Set(store.issues.filter { ids.contains($0.id) }.map(\.priority))
        for value in Self.priorities {
            let item = NSMenuItem(
                title: "P\(value)", action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            item.state = current == [value] ? .on : .off
            item.target = MenuAction.shared
            item.representedObject = MenuAction.Payload {
                Task { await store.setPriority(value, for: ids) }
            }
            menu.addItem(item)
        }
        return menu
    }

    /// The row context menu.
    ///
    /// Structured around the three cases from the start — none, one, several —
    /// because items added later will differ between them, and retrofitting
    /// that distinction is how a menu ends up offering "Copy ID" for a
    /// right-click on empty space.
    private func rowMenu(for ids: Set<Issue.ID>) -> NSMenu? {
        // Right-clicking the background. macOS shows no menu here rather than
        // a menu of actions with nothing to act on, and a Copy ID in this
        // state would replace the clipboard with an empty string.
        guard !ids.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(
            MenuAction.item(ids.count == 1 ? "Copy ID" : "Copy \(ids.count) IDs") {
                store.copyIDs(ids)
            })

        menu.addItem(.separator())

        let priority = NSMenuItem(
            title: ids.count == 1 ? "Priority" : "Priority of \(ids.count) Beads",
            action: nil, keyEquivalent: "")
        priority.submenu = priorityMenu(Self.specs[1], ids)
        priority.isEnabled = store.canEditBeads
        menu.addItem(priority)

        if ids.count == 1, let id = ids.first {
            menu.addItem(.separator())
            menu.addItem(
                MenuAction.item("Show History") {
                    store.select(id: id)
                    store.surface = .history
                })
        }
        return menu
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Runs a closure from an `NSMenuItem`.
///
/// `NSMenu` predates closures and wants a target/action pair, so something has
/// to hold the closure and stay alive while the menu is up. A single shared
/// target keeps that lifetime question out of every menu that needs one.
@MainActor
final class MenuAction: NSObject {
    static let shared = MenuAction()

    final class Payload: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? Payload)?.run()
    }

    /// A menu item that runs `action` when chosen.
    static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = Payload(action)
        return item
    }
}
extension IssueRow {
    /// A count as the list writes it: an em dash for zero.
    ///
    /// Zero is a real value here, not an absent one — the dash is de-emphasis,
    /// not the "absent, never zero" rule, which is about metrics that have not
    /// been computed.
    static func countLabel(_ value: Int) -> String { value == 0 ? "—" : "\(value)" }

    /// The combined column's text, e.g. `7 / 1`.
    ///
    /// The cell draws the two sides separately so each can be de-emphasised on
    /// its own; this is the same content as one string, for the tooltip and for
    /// tests that should not have to read pixels.
    var blockedSummary: String {
        Self.blockedSummary(blocks: blocks, blockedBy: blockedBy)
    }

    /// Static so it can be asserted directly. `IssueRow` builds itself from a
    /// `GraphMetrics`, so constructing one with chosen counts means standing up
    /// a metrics value — which tests the wrong thing.
    static func blockedSummary(blocks: Int, blockedBy: Int) -> String {
        "\(countLabel(blocks)) / \(countLabel(blockedBy))"
    }
}

struct IssueRow: Identifiable {
    let issue: Issue
    let blocks: Int
    let blockedBy: Int
    let pageRank: Double?

    var id: Issue.ID { issue.id }
    var priority: Int { issue.priority }

    // Sort keys. Lowercased for text so ordering is not case-split, and
    // defaulted for dates so a bead with no timestamp sorts oldest rather
    // than being dropped.
    var titleKey: String { issue.title.lowercased() }
    var statusKey: Int { issue.status.workflowRank }
    var labelsKey: String { issue.labels.joined(separator: ",").lowercased() }
    var createdKey: Date { issue.createdAt ?? .distantPast }
    var updatedKey: Date { issue.updatedAt ?? .distantPast }
    /// Absent PageRank sorts as zero *for the comparator only*; the binding
    /// refuses the sort outright until Phase 2 lands, so this is never the
    /// ordering the user actually sees.
    var pageRankKey: Double { pageRank ?? 0 }

    init(issue: Issue, metrics: GraphMetrics) {
        self.issue = issue
        self.blocks = metrics.blocks(issue.id)
        self.blockedBy = metrics.blockedBy(issue.id)
        self.pageRank = metrics.pageRank?[issue.id]
    }

    /// The comparator that renders `column` in the given direction.
    static func comparator(
        for column: SortColumn, ascending: Bool
    ) -> KeyPathComparator<IssueRow>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .id: return KeyPathComparator(\IssueRow.id, order: order)
        case .title: return KeyPathComparator(\IssueRow.titleKey, order: order)
        case .status: return KeyPathComparator(\IssueRow.statusKey, order: order)
        case .priority: return KeyPathComparator(\IssueRow.priority, order: order)
        case .blocks: return KeyPathComparator(\IssueRow.blocks, order: order)
        case .blockedBy: return KeyPathComparator(\IssueRow.blockedBy, order: order)
        case .pageRank: return KeyPathComparator(\IssueRow.pageRankKey, order: order)
        case .labels: return KeyPathComparator(\IssueRow.labelsKey, order: order)
        case .created: return KeyPathComparator(\IssueRow.createdKey, order: order)
        case .updated: return KeyPathComparator(\IssueRow.updatedKey, order: order)
        }
    }

    /// The column a comparator came from.
    ///
    /// Matching on the key path is what lets the header write back into the
    /// store's single sort value instead of into table-local state.
    static func column(of comparator: KeyPathComparator<IssueRow>) -> SortColumn? {
        switch comparator.keyPath {
        case \IssueRow.id: .id
        case \IssueRow.titleKey: .title
        case \IssueRow.statusKey: .status
        case \IssueRow.priority: .priority
        case \IssueRow.blocks: .blocks
        case \IssueRow.blockedBy: .blockedBy
        case \IssueRow.pageRankKey: .pageRank
        case \IssueRow.labelsKey: .labels
        case \IssueRow.createdKey: .created
        case \IssueRow.updatedKey: .updated
        default: nil
        }
    }
}

/// Renders a Phase-2 value, or *why* there isn't one. Never shows a bare 0.
struct MetricCell: View {
    let value: Double?
    let status: MetricStatusEntry?
    var format: (Double) -> String

    var body: some View {
        if let value {
            HStack(spacing: 3) {
                Text(format(value)).monospacedDigit()
                if let entry = status, entry.state == .approx {
                    Image(systemName: "tildecircle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(entry.annotation ?? "approximate")
                }
            }
        } else {
            Text(placeholder)
                .foregroundStyle(.tertiary)
                .help(status?.annotation ?? "Not computed yet")
        }
    }

    private var placeholder: String {
        switch status?.state {
        case .timeout: "timeout"
        case .skipped: "skipped"
        case .none, .pending: "—"
        default: "—"
        }
    }
}

/// One label, drawn as a pill.
///
/// Unlike ``StatusChip`` the fill is neutral. A label carries no status
/// meaning, so the pill's job is only to bound one label against the next —
/// which a comma-joined string does not do once there are more than two.
///
/// The fill is heavier than ``StatusChip``'s 0.12 because it is grey rather
/// than tinted: measured against the window background, a neutral capsule at
/// 0.12 is indistinguishable from bare text (ink 0.049 vs 0.043), so the pill
/// would have been invisible. At 0.18 it reads.
struct LabelPill: View {
    let label: String
    /// True when this label is one the list is currently filtered by.
    var isFiltered: Bool = false

    var body: some View {
        Text(label)
            .font(.caption)
            // Weight as well as colour: a filtered pill has to be
            // distinguishable in monochrome and to a colour-blind reader, the
            // same reasoning that gives ``StatusChip`` a symbol beside its
            // tint.
            .fontWeight(isFiltered ? .semibold : .regular)
            .lineLimit(1)
            .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
    }

    /// The capsule behind the label.
    ///
    /// The neutral fill is heavier than ``StatusChip``'s 0.12 because it is
    /// grey rather than tinted: measured against the window background, a
    /// neutral capsule at 0.12 is indistinguishable from bare text (ink 0.049
    /// vs 0.043). The filtered fill is coloured, so it reads at a lower
    /// opacity — but it is still set deliberately rather than shared, and the
    /// tests compare the two rather than trusting a number.
    private var fill: Color {
        isFiltered ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.18)
    }
}

struct StatusChip: View {
    let status: IssueStatus

    var body: some View {
        Label(status.displayName, systemImage: status.symbolName)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// Colour is never the only signal — the SF Symbol carries the same
    /// meaning for colour-blind users and in monochrome.
    private var tint: Color {
        switch status {
        case .open: .blue
        case .inProgress: .orange
        case .blocked: .red
        case .review: .purple
        case .deferred, .draft: .gray
        case .pinned, .hooked: .teal
        case .closed: .green
        case .tombstone: .secondary
        case .unknown: .secondary
        }
    }
}
