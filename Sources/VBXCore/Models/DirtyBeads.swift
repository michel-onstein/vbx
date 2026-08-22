import Foundation

/// What separates the beads on disk from the beads in the last commit.
///
/// ## Why against git rather than as state of vbx's own
///
/// vbx writes through `br`, which updates the database and re-exports
/// `.beads/issues.jsonl` immediately. Nothing commits it, so after a few edits
/// there is no way to see what a commit would contain.
///
/// Tracking "what have I changed?" inside the app would need somewhere to keep
/// it, and that somewhere falls out of step the moment anything happens outside
/// the app — a `br` run in a terminal, a `git checkout`, a commit, a pull. The
/// definition here needs no storage at all: a bead is dirty when its record
/// differs from the same record at `HEAD`. That is true or false by inspection,
/// always, however the file got that way.
///
/// ## Three cases, not one
///
/// They are genuinely different, and lumping them together loses the one that
/// matters most.
public struct BeadDirtyState: Equatable, Sendable {
    /// Present in both, and different.
    public var changed: Set<String>
    /// On disk, absent from the commit. A brand-new bead is the likeliest
    /// thing to forget to commit, so it must not be silently excluded.
    public var added: Set<String>
    /// In the commit, gone from disk. There is no row to mark — nothing on
    /// screen represents it — but it is part of what a commit would contain,
    /// so a count that omitted it would be wrong.
    public var removed: Set<String>

    /// False when there is nothing to compare against: no git repository, no
    /// commits yet, or a workspace whose beads are not in one.
    ///
    /// Distinct from "everything is clean". Absent, never zero — a workspace
    /// with no history must not render as a workspace with nothing outstanding.
    public var isKnown: Bool

    public init(
        changed: Set<String> = [], added: Set<String> = [],
        removed: Set<String> = [], isKnown: Bool = true
    ) {
        self.changed = changed
        self.added = added
        self.removed = removed
        self.isKnown = isKnown
    }

    /// Nothing to compare against.
    public static let unknown = BeadDirtyState(isKnown: false)

    /// The beads with a row to mark.
    public var marked: Set<String> { changed.union(added) }

    /// Everything a commit would carry, including deletions.
    public var total: Int { changed.count + added.count + removed.count }

    public var isClean: Bool { isKnown && total == 0 }

    public func isDirty(_ id: String) -> Bool { changed.contains(id) || added.contains(id) }

    /// Why a row is marked, for a tooltip. Nil when it is not.
    ///
    /// Colour alone is not an affordance, so every marked row has to be able to
    /// say what the colour means.
    public func reason(for id: String) -> String? {
        if added.contains(id) { return "Added since the last commit" }
        if changed.contains(id) { return "Modified since the last commit" }
        return nil
    }

    /// Compares the working bead set against the committed one.
    ///
    /// **Records, not bytes.** `.beads/issues.jsonl` is a whole-file export and
    /// `br` rewrites all of it on any change, so key order and formatting move
    /// without any bead moving. A byte comparison would light up every row
    /// after an unrelated write.
    ///
    /// `updated_at` counts as a difference, and deliberately: `br` stamps it on
    /// every write, so a record differing only there is still a record that was
    /// written and is not yet committed. Excluding it would call a real pending
    /// change clean.
    public static func compare(working: [Issue], committed: [Issue]) -> BeadDirtyState {
        let workingByID = Dictionary(working.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let committedByID = Dictionary(committed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var changed: Set<String> = []
        for (id, bead) in workingByID {
            guard let before = committedByID[id] else { continue }
            if bead != before { changed.insert(id) }
        }
        return BeadDirtyState(
            changed: changed,
            added: Set(workingByID.keys).subtracting(committedByID.keys),
            removed: Set(committedByID.keys).subtracting(workingByID.keys),
            isKnown: true)
    }
}
