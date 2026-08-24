import VBXCore
import SwiftUI

/// One column of the bead list, declared once.
///
/// The SwiftUI `Table` this replaces declared each column three times over — a
/// `TableColumn` for the content, a `customizationID` for persistence, and an
/// entry in a title→id dictionary so the hidden-column markers could find it.
/// Keeping those in step was manual, and a test existed purely to catch them
/// drifting. Here a column is one value and everything is read from it.
struct BeadColumnSpec: Identifiable, Sendable {
    /// Stable across launches: it is the key stored layouts are written under.
    let id: String
    let title: String
    /// The ordering a header click applies, or nil when the column is not
    /// sortable — the type glyph has no useful order of its own.
    let sort: SortColumn?
    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// Columns that must stay on screen whatever a stored layout says.
    ///
    /// The identifier, because every context menu, bead link and URL is keyed
    /// by it; the type glyph, because it is 22pt of context rather than a
    /// column to manage. They are also kept out of the header's show/hide menu,
    /// because a control that is present and inert is worse than none.
    let isProtected: Bool
    /// Whether a double-click on this cell starts an edit.
    let editing: Editing?
    /// Which edge hosted content sits against.
    ///
    /// Its own type rather than SwiftUI's `Alignment` so the spec stays a plain
    /// `Sendable` value, and so the only two answers a column may give are the
    /// two that exist.
    let contentAlignment: CellAlignment
    /// How far hosted content is held off the cell's leading edge.
    ///
    /// 4pt suits a column with room. The uncommitted gutter is 10pt wide, where
    /// 4pt each side leaves 2pt to draw a character in and the glyph clips, so
    /// a narrow column says so here.
    let contentInset: CGFloat
    /// The same for the trailing edge, defaulting to ``contentInset``.
    ///
    /// **Negative overhangs**, which is the point of it being separate. An
    /// inset-style table sets `intercellSpacing.width` to 17pt, and that gap —
    /// not the 10pt column — is what stands between the uncommitted mark and
    /// the id it belongs to. The spacing is a property of the table, so it
    /// cannot be narrowed for one column without narrowing every column; a
    /// trailing overhang moves the one glyph into the gap instead and leaves
    /// the rest of the table alone.
    ///
    /// Overhanging is only safe leftwards-into-a-gap like this: it draws over
    /// spacing that belongs to no column. Enough overhang to reach the *next*
    /// column would draw over that column's content.
    let contentTrailingInset: CGFloat

    enum CellAlignment: Sendable {
        case leading
        case trailing
    }

    enum Editing: Sendable {
        /// A field editor over the cell, committing on Return or on losing
        /// focus, abandoning on Escape.
        case text
        /// A menu at the cell, for a small closed set of values.
        case priority
    }

    init(
        id: String,
        title: String,
        sort: SortColumn? = nil,
        width: CGFloat,
        minWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        isProtected: Bool = false,
        editing: Editing? = nil,
        contentAlignment: CellAlignment = .leading,
        contentInset: CGFloat = 4,
        contentTrailingInset: CGFloat? = nil
    ) {
        self.id = id
        self.title = title
        self.sort = sort
        self.width = width
        self.minWidth = minWidth ?? width
        self.maxWidth = maxWidth ?? max(width, 10_000)
        self.isProtected = isProtected
        self.editing = editing
        self.contentAlignment = contentAlignment
        self.contentInset = contentInset
        self.contentTrailingInset = contentTrailingInset ?? contentInset
    }
}

/// Which columns are shown, in what order, at what width.
///
/// Replaces `TableColumnCustomization`, which was a SwiftUI type and could only
/// describe a SwiftUI table. Stored as JSON under a new key, so an old stored
/// layout is ignored rather than misread — the column set is the same, but
/// nothing about the old encoding is worth decoding, and a layout that resets
/// once costs a user a few seconds.
struct BeadTableLayout: Equatable, Sendable {
    /// Column ids, in display order. Ids absent from this list keep their
    /// declared position, so adding a column does not require a migration.
    var order: [String] = []
    var hidden: Set<String> = []
    var widths: [String: Double] = [:]

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    /// The specs in stored order, with unknown ids dropped and new ones kept.
    ///
    /// Both halves matter: an id in the stored order that no longer exists is a
    /// column that was removed, and a spec missing from the order is one that
    /// was added since the layout was written.
    func arrange(_ specs: [BeadColumnSpec]) -> [BeadColumnSpec] {
        let byID = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
        var arranged = order.compactMap { byID[$0] }
        let placed = Set(arranged.map(\.id))
        for spec in specs where !placed.contains(spec.id) {
            arranged.append(spec)
        }
        return arranged
    }

    /// Protected columns are forced visible on the way in and out.
    ///
    /// Leaving them out of the header menu does not enforce anything — a stored
    /// layout marking them hidden still hid them, which was measurable in the
    /// SwiftUI version before it sanitised the same way. The menu entry and the
    /// enforcement are separate problems.
    mutating func sanitize(against specs: [BeadColumnSpec]) {
        for spec in specs where spec.isProtected {
            hidden.remove(spec.id)
        }
        let known = Set(specs.map(\.id))
        hidden.formIntersection(known)
        order = order.filter { known.contains($0) }
        widths = widths.filter { known.contains($0.key) }
    }
}

/// Stored as a JSON string so `@AppStorage` can hold it.
///
/// **`BeadTableLayout` deliberately does not conform to `Codable`.** Conforming
/// to both `Codable` and `RawRepresentable` with a `Codable` raw value is a
/// trap: the standard library supplies default `Codable` implementations for
/// every `RawRepresentable`, and those encode the *raw value* — so `rawValue`
/// calling `JSONEncoder().encode(self)` re-entered `rawValue`, recursed until
/// the stack ran out, and took the process down with SIGSEGV. No message, no
/// failing expectation, just a dead test runner.
///
/// Coding a separate private type removes the cycle at its source: there is no
/// `Codable` conformance here for those defaults to attach to.
extension BeadTableLayout: RawRepresentable {
    private struct Storage: Codable {
        var order: [String]
        var hidden: [String]
        var widths: [String: Double]
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
            let stored = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            // A layout that cannot be read is not worth failing over: the
            // default is a perfectly good table.
            return nil
        }
        self.init(
            order: stored.order, hidden: Set(stored.hidden), widths: stored.widths)
    }

    var rawValue: String {
        // Sorted so the encoding is stable: `@AppStorage` writes on every
        // change, and a set's iteration order is not fixed, so an unsorted
        // encoding would rewrite preferences when nothing had changed.
        let stored = Storage(order: order, hidden: hidden.sorted(), widths: widths)
        guard let data = try? JSONEncoder().encode(stored),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
