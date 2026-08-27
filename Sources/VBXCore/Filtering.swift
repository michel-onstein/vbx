import Foundation

/// The four top-level filters bv binds to `o`, `r`, `c` and `a`.
public enum IssueFilter: String, CaseIterable, Sendable, Identifiable {
    /// Open and in-progress.
    case open
    /// Actionable: open with no unresolved blocking dependency.
    case ready
    case closed
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .open: "Open"
        case .ready: "Ready"
        case .closed: "Closed"
        case .all: "All"
        }
    }

    public var symbolName: String {
        switch self {
        case .open: "circle"
        case .ready: "bolt.circle"
        case .closed: "checkmark.circle"
        case .all: "tray.full"
        }
    }

    /// bv's single-key binding for this filter.
    public var shortcut: Character {
        switch self {
        case .open: "o"
        case .ready: "r"
        case .closed: "c"
        case .all: "a"
        }
    }
}

/// A list column the table can be ordered by.
///
/// Separate from ``SortMode`` because a column carries no direction — a header
/// click supplies that — while a sort mode is a fixed, named ordering.
public enum SortColumn: String, CaseIterable, Sendable, Identifiable {
    case id
    case title
    case status
    case priority
    case blocks
    case blockedBy
    case pageRank
    /// How many commits the engine attributed to a bead.
    case commits
    case labels
    case created
    case updated

    public var id: String { rawValue }

    /// True when ordering by this column needs Phase-2 metrics.
    ///
    /// Only `pageRank` does. `blocks` and `blockedBy` come from degree, which
    /// is Phase 1 and therefore ready the moment the workspace opens.
    public var requiresPhase2: Bool { self == .pageRank }

    /// True when ordering by this column needs the git correlation report.
    ///
    /// The same shape as ``requiresPhase2`` and for the same reason: until the
    /// walk has finished, every bead's count is *unknown*, and ordering by it
    /// would silently sort by zeros — putting beads in an order the screen
    /// cannot explain.
    public var requiresHistory: Bool { self == .commits }

    /// The direction a first click on this column's header applies.
    ///
    /// Counts and scores read most usefully largest-first; names and dates
    /// smallest-first.
    public var defaultAscending: Bool {
        switch self {
        case .blocks, .blockedBy, .pageRank, .commits, .created, .updated: false
        case .id, .title, .status, .priority, .labels: true
        }
    }
}

/// An ordering for the issue list.
///
/// Every ordering the UI can be in is one case here — the toolbar menu, bv's
/// `s` cycle and the table's column headers all read and write this single
/// value, which is what stops the header and the cycle disagreeing about what
/// the current order is.
public enum SortMode: String, CaseIterable, Sendable, Identifiable {
    /// Priority ascending, then created descending — bv's default. The only
    /// ordering that is not expressible as a single column.
    case `default`
    case idAscending
    case idDescending
    case titleAscending
    case titleDescending
    case statusAscending
    case statusDescending
    /// Priority ascending (P0 first) — bv's named "priority" ordering.
    case priority
    case priorityDescending
    case blocksDescending
    case blocksAscending
    case blockedByDescending
    case blockedByAscending
    case commitsDescending
    case commitsAscending
    case labelsAscending
    case labelsDescending
    case createdAscending
    case createdDescending
    /// Most recently updated first — bv's named "recently updated" ordering.
    case updated
    case updatedAscending
    /// Order by computed impact, largest first. Requires Phase 2.
    case impact
    case impactAscending

    public var id: String { rawValue }

    /// The orderings the toolbar menu lists and bv's `s` key cycles through.
    ///
    /// Every column ordering is reachable from its header, so listing all of
    /// them here would bury the named ones — and would make `s` walk twenty
    /// steps where bv walks six.
    public static let cycleCases: [SortMode] = [
        .default, .createdAscending, .createdDescending, .priority, .updated, .impact,
    ]

    public var displayName: String {
        switch self {
        case .default: "Default"
        case .idAscending: "ID ↑"
        case .idDescending: "ID ↓"
        case .titleAscending: "Title ↑"
        case .titleDescending: "Title ↓"
        case .statusAscending: "Status ↑"
        case .statusDescending: "Status ↓"
        case .priority: "Priority"
        case .priorityDescending: "Priority ↓"
        case .blocksDescending: "Blocks ↓"
        case .blocksAscending: "Blocks ↑"
        case .blockedByDescending: "Blocked by ↓"
        case .blockedByAscending: "Blocked by ↑"
        case .commitsDescending: "Commits ↓"
        case .commitsAscending: "Commits ↑"
        case .labelsAscending: "Labels ↑"
        case .labelsDescending: "Labels ↓"
        case .createdAscending: "Created ↑"
        case .createdDescending: "Created ↓"
        case .updated: "Recently Updated"
        case .updatedAscending: "Least Recently Updated"
        case .impact: "Impact"
        case .impactAscending: "Impact ↑"
        }
    }

    /// The column this ordering sorts by, or nil when it is not one column —
    /// `.default` orders by priority *and* creation date together.
    public var column: SortColumn? {
        switch self {
        case .default: nil
        case .idAscending, .idDescending: .id
        case .titleAscending, .titleDescending: .title
        case .statusAscending, .statusDescending: .status
        case .priority, .priorityDescending: .priority
        case .blocksAscending, .blocksDescending: .blocks
        case .blockedByAscending, .blockedByDescending: .blockedBy
        case .impact, .impactAscending: .pageRank
        case .commitsAscending, .commitsDescending: .commits
        case .labelsAscending, .labelsDescending: .labels
        case .createdAscending, .createdDescending: .created
        case .updated, .updatedAscending: .updated
        }
    }

    /// Which way this ordering runs. `.default` reports ascending because its
    /// leading key, priority, ascends.
    /// Exhaustive on purpose, with no catch-all.
    ///
    /// It had one, falling through to descending, and it cost exactly what a
    /// silent default costs: `commitsAscending` was added, matched the
    /// catch-all, and sorted descending while claiming to ascend. A new case
    /// now has to be classified here or the build stops.
    public var ascending: Bool {
        switch self {
        case .default, .idAscending, .titleAscending, .statusAscending, .priority,
            .blocksAscending, .blockedByAscending, .commitsAscending, .labelsAscending,
            .createdAscending, .updatedAscending, .impactAscending:
            true
        case .idDescending, .titleDescending, .statusDescending, .priorityDescending,
            .blocksDescending, .blockedByDescending, .commitsDescending, .labelsDescending,
            .createdDescending, .updated, .impact:
            false
        }
    }

    /// The ordering that sorts by `column` in the given direction.
    public static func ordering(by column: SortColumn, ascending: Bool) -> SortMode {
        switch column {
        case .id: ascending ? .idAscending : .idDescending
        case .title: ascending ? .titleAscending : .titleDescending
        case .status: ascending ? .statusAscending : .statusDescending
        case .priority: ascending ? .priority : .priorityDescending
        case .blocks: ascending ? .blocksAscending : .blocksDescending
        case .blockedBy: ascending ? .blockedByAscending : .blockedByDescending
        case .pageRank: ascending ? .impactAscending : .impact
        case .commits: ascending ? .commitsAscending : .commitsDescending
        case .labels: ascending ? .labelsAscending : .labelsDescending
        case .created: ascending ? .createdAscending : .createdDescending
        case .updated: ascending ? .updatedAscending : .updated
        }
    }

    /// True when this ordering needs Phase-2 metrics, so the UI can keep it
    /// inert until they land rather than sorting by silent zeros.
    public var requiresPhase2: Bool { column?.requiresPhase2 ?? false }

    /// True when this ordering needs the correlation report, so the UI can keep
    /// it inert until the walk lands rather than sorting by silent zeros.
    public var requiresHistory: Bool { column?.requiresHistory ?? false }

    /// The ordering to use once `hidden` columns are off screen.
    ///
    /// Sorting by a column nobody can see leaves the list in an order with no
    /// visible explanation: the header that would carry the chevron is gone,
    /// so the rows simply look shuffled. Falling back to `.default` is the
    /// honest answer — it is a named ordering the toolbar can still show.
    ///
    /// `.default` itself names no column, so it can never be the hidden one.
    public func whenColumnsHidden(_ hidden: Set<SortColumn>) -> SortMode {
        guard let column, hidden.contains(column) else { return self }
        return .default
    }
}

/// Applies filters, search and sorting. Pure and synchronous so it can run
/// during view updates without touching the engine.
public struct IssueQuery: Sendable {
    public var filter: IssueFilter
    public var searchText: String
    public var labels: Set<String>
    public var assignees: Set<String>
    public var sort: SortMode

    public init(
        filter: IssueFilter = .open,
        searchText: String = "",
        labels: Set<String> = [],
        assignees: Set<String> = [],
        sort: SortMode = .default
    ) {
        self.filter = filter
        self.searchText = searchText
        self.labels = labels
        self.assignees = assignees
        self.sort = sort
    }

    /// - Parameters:
    ///   - actionable: ids the engine reports as actionable. Required for
    ///     `.ready`, because readiness is a graph property, not a field.
    ///   - metrics: used only by `.impact` sorting.
    public func apply(
        to issues: [Issue],
        actionable: Set<String> = [],
        metrics: GraphMetrics? = nil,
        commits: [String: Int]? = nil
    ) -> [Issue] {
        var result = issues.filter { matches($0, actionable: actionable) }
        result = Self.rank(result, query: searchText)
        return sorted(result, metrics: metrics, commits: commits)
    }

    private func matches(_ issue: Issue, actionable: Set<String>) -> Bool {
        switch filter {
        case .open where !issue.status.isOpen: return false
        case .ready where !actionable.contains(issue.id): return false
        case .closed where !issue.status.isClosed: return false
        case .all where issue.status.isTombstone: return false
        default: break
        }
        if !labels.isEmpty, labels.isDisjoint(with: Set(issue.labels)) { return false }
        if !assignees.isEmpty {
            guard let a = issue.assignee, assignees.contains(a) else { return false }
        }
        return true
    }

    private func sorted(
        _ issues: [Issue], metrics: GraphMetrics?, commits: [String: Int]? = nil
    ) -> [Issue] {
        // A search query imposes its own relevance order; re-sorting would
        // discard it.
        guard searchText.isEmpty else { return issues }

        // Ordering by a metric that has not been computed would sort by
        // absent values while looking like it worked. The input order is
        // returned untouched instead, which is what the UI's disabled header
        // is telling the user.
        if sort.requiresPhase2, metrics?.pageRank == nil { return issues }

        guard let column = sort.column else {
            // .default: priority ascending, then newest first.
            return issues.sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
        }

        let ascending = sort.ascending
        switch column {
        case .id:
            return order(issues, ascending) { $0.id }
        case .title:
            return order(issues, ascending) { $0.title.lowercased() }
        case .status:
            return order(issues, ascending) { $0.status.workflowRank }
        case .priority:
            return order(issues, ascending) { $0.priority }
        case .blocks:
            return order(issues, ascending) { metrics?.blocks($0.id) ?? 0 }
        case .blockedBy:
            return order(issues, ascending) { metrics?.blockedBy($0.id) ?? 0 }
        case .pageRank:
            return order(issues, ascending) { metrics?.pageRank?[$0.id] ?? 0 }
        case .commits:
            // Absent sorts as zero *for the comparator only*. The UI refuses
            // the ordering outright until the walk has landed
            // (``SortColumn/requiresHistory``), so this is never the order
            // anyone actually sees with the counts unknown — the same
            // arrangement PageRank has.
            return order(issues, ascending) { commits?[$0.id] ?? 0 }
        case .labels:
            return order(issues, ascending) { $0.labels.joined(separator: ",").lowercased() }
        case .created:
            return order(issues, ascending) { $0.createdAt ?? .distantPast }
        case .updated:
            return order(issues, ascending) { $0.updatedAt ?? .distantPast }
        }
    }

    /// Sorts by one key, breaking ties on id.
    ///
    /// The tie-break is not cosmetic: without it, rows carrying equal keys —
    /// every bead at the same priority, every bead with no PageRank — would
    /// reshuffle on each redraw.
    private func order<Key: Comparable>(
        _ issues: [Issue], _ ascending: Bool, by key: (Issue) -> Key
    ) -> [Issue] {
        issues.sorted {
            let a = key($0), b = key($1)
            if a == b { return $0.id < $1.id }
            return ascending ? a < b : a > b
        }
    }

    /// Filters to matches and orders them by descending fuzzy score.
    public static func rank(_ issues: [Issue], query: String) -> [Issue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return issues }

        return
            issues
            .compactMap { issue -> (Issue, Int)? in
                guard let score = fuzzyScore(issue: issue, query: q) else { return nil }
                return (issue, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .map(\.0)
    }

    /// Subsequence match over the fields bv indexes, with a bonus for stronger
    /// match kinds so exact and prefix hits outrank scattered subsequences.
    static func fuzzyScore(issue: Issue, query: String) -> Int? {
        let q = query.lowercased()
        var best: Int?

        func consider(_ haystack: String, weight: Int) {
            guard !haystack.isEmpty else { return }
            let h = haystack.lowercased()
            var score: Int?
            if h == q {
                score = 1000
            } else if h.hasPrefix(q) {
                score = 700
            } else if h.contains(q) {
                score = 400
            } else if isSubsequence(q, of: h) {
                score = 150
            }
            if let s = score {
                let total = s + weight
                if best == nil || total > best! { best = total }
            }
        }

        consider(issue.id, weight: 60)
        consider(issue.title, weight: 50)
        for label in issue.labels { consider(label, weight: 25) }
        consider(issue.assignee ?? "", weight: 10)
        consider(issue.description, weight: 0)
        return best
    }

    /// True when every character of `needle` appears in `haystack` in order.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var i = needle.startIndex
        guard i != needle.endIndex else { return true }
        for ch in haystack where ch == needle[i] {
            i = needle.index(after: i)
            if i == needle.endIndex { return true }
        }
        return false
    }
}

extension Array where Element == Issue {
    /// All labels present, sorted, with their counts.
    public var labelCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for issue in self {
            for label in issue.labels { counts[label, default: 0] += 1 }
        }
        return counts.map { (label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// All assignees present, sorted by name.
    public var assignees: [String] {
        Set(compactMap(\.assignee)).filter { !$0.isEmpty }.sorted()
    }

    public func grouped(by status: IssueStatus) -> [Issue] {
        filter { $0.status == status }
    }
}
