import Foundation

/// A point the time-travel scrubber can jump to.
///
/// Only commits that changed the beads file are offered: a commit that did not
/// leaves the bead set identical, so a scrubber over every commit would be
/// mostly no-op steps.
public struct RevisionInfo: Codable, Sendable, Hashable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var subject: String
    public var author: String
    public var when: Date?

    public var id: String { sha }

    private enum CodingKeys: String, CodingKey {
        case sha, subject, author, when
        case shortSHA = "short_sha"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        shortSHA = try c.decodeIfPresent(String.self, forKey: .shortSHA) ?? String(sha.prefix(7))
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        when = try? c.decodeIfPresent(Date.self, forKey: .when)
    }

    public init(sha: String, subject: String, author: String = "", when: Date? = nil) {
        self.sha = sha
        self.shortSHA = String(sha.prefix(7))
        self.subject = subject
        self.author = author
        self.when = when
    }
}

public struct RevisionList: Codable, Sendable, Hashable {
    public var revisions: [RevisionInfo]
    public var count: Int

    private enum CodingKeys: String, CodingKey { case revisions, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revisions = try c.decodeIfPresent([RevisionInfo].self, forKey: .revisions) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? revisions.count
    }

    public init(revisions: [RevisionInfo] = []) {
        self.revisions = revisions
        self.count = revisions.count
    }

    public static let empty = RevisionList()
}

/// The bead set as of one revision.
public struct WorkspaceSnapshot: Codable, Sendable, Hashable {
    /// What the caller asked for — `HEAD~3`, a branch, a short SHA.
    public var requestedRevision: String
    /// The commit that expression actually named.
    ///
    /// Always shown in preference to the request: `HEAD~3` means something
    /// different tomorrow, and displaying the raw input would keep claiming to
    /// show a snapshot it is no longer showing.
    public var resolvedRevision: String
    public var shortRevision: String
    public var timestamp: Date?
    public var issueCount: Int
    public var dataHash: String
    public var issues: [Issue]
    /// Beads whose committed state could not be read: in a multi-repository
    /// workspace, the records of a member with no repository or no commits.
    ///
    /// Not in ``issues`` and not the same as absent from it — left out of the
    /// comparison, they would all read as added. Absent, never zero
    /// (vbx-d1c, ADR-015).
    public var unknownIDs: Set<String>

    private enum CodingKeys: String, CodingKey {
        case timestamp, issues
        case unknownIDs = "unknown_ids"
        case requestedRevision = "requested_revision"
        case resolvedRevision = "resolved_revision"
        case shortRevision = "short_revision"
        case issueCount = "issue_count"
        case dataHash = "data_hash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedRevision = try c.decodeIfPresent(String.self, forKey: .requestedRevision) ?? ""
        resolvedRevision = try c.decodeIfPresent(String.self, forKey: .resolvedRevision) ?? ""
        shortRevision =
            try c.decodeIfPresent(String.self, forKey: .shortRevision)
            ?? String(resolvedRevision.prefix(7))
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        dataHash = try c.decodeIfPresent(String.self, forKey: .dataHash) ?? ""
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        unknownIDs = Set(try c.decodeIfPresent([String].self, forKey: .unknownIDs) ?? [])
    }
}

/// What happened to one bead between two revisions.
public enum DiffBadge: String, Codable, Sendable, Hashable, CaseIterable {
    case new
    case closed
    case reopened
    case modified
    case removed

    public var displayName: String {
        switch self {
        case .new: "NEW"
        case .closed: "CLOSED"
        case .reopened: "REOPENED"
        case .modified: "MODIFIED"
        case .removed: "REMOVED"
        }
    }

    public var symbolName: String {
        switch self {
        case .new: "plus.circle.fill"
        case .closed: "checkmark.circle.fill"
        case .reopened: "arrow.uturn.backward.circle.fill"
        case .modified: "pencil.circle.fill"
        case .removed: "minus.circle.fill"
        }
    }
}

/// One field that changed on one bead.
public struct FieldChange: Codable, Sendable, Hashable, Identifiable {
    public var field: String
    public var oldValue: String
    public var newValue: String

    public var id: String { field }

    private enum CodingKeys: String, CodingKey {
        case field
        case oldValue = "old_value"
        case newValue = "new_value"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? ""
        oldValue = try c.decodeIfPresent(String.self, forKey: .oldValue) ?? ""
        newValue = try c.decodeIfPresent(String.self, forKey: .newValue) ?? ""
    }
}

public struct ModifiedIssue: Codable, Sendable, Hashable, Identifiable {
    public var issueID: String
    public var title: String
    public var changes: [FieldChange]

    public var id: String { issueID }

    private enum CodingKeys: String, CodingKey {
        case title, changes
        case issueID = "issue_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        changes = try c.decodeIfPresent([FieldChange].self, forKey: .changes) ?? []
    }
}

public struct DiffSummary: Codable, Sendable, Hashable {
    public var totalChanges: Int
    public var issuesAdded: Int
    public var issuesClosed: Int
    public var issuesRemoved: Int
    public var issuesReopened: Int
    public var issuesModified: Int
    public var cyclesIntroduced: Int
    public var cyclesResolved: Int
    public var netIssueChange: Int
    /// `improving`, `degrading` or `stable`, as bv rates it.
    public var healthTrend: String

    private enum CodingKeys: String, CodingKey {
        case totalChanges = "total_changes"
        case issuesAdded = "issues_added"
        case issuesClosed = "issues_closed"
        case issuesRemoved = "issues_removed"
        case issuesReopened = "issues_reopened"
        case issuesModified = "issues_modified"
        case cyclesIntroduced = "cycles_introduced"
        case cyclesResolved = "cycles_resolved"
        case netIssueChange = "net_issue_change"
        case healthTrend = "health_trend"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalChanges = try c.decodeIfPresent(Int.self, forKey: .totalChanges) ?? 0
        issuesAdded = try c.decodeIfPresent(Int.self, forKey: .issuesAdded) ?? 0
        issuesClosed = try c.decodeIfPresent(Int.self, forKey: .issuesClosed) ?? 0
        issuesRemoved = try c.decodeIfPresent(Int.self, forKey: .issuesRemoved) ?? 0
        issuesReopened = try c.decodeIfPresent(Int.self, forKey: .issuesReopened) ?? 0
        issuesModified = try c.decodeIfPresent(Int.self, forKey: .issuesModified) ?? 0
        cyclesIntroduced = try c.decodeIfPresent(Int.self, forKey: .cyclesIntroduced) ?? 0
        cyclesResolved = try c.decodeIfPresent(Int.self, forKey: .cyclesResolved) ?? 0
        netIssueChange = try c.decodeIfPresent(Int.self, forKey: .netIssueChange) ?? 0
        healthTrend = try c.decodeIfPresent(String.self, forKey: .healthTrend) ?? "stable"
    }

    public init() {
        totalChanges = 0
        issuesAdded = 0
        issuesClosed = 0
        issuesRemoved = 0
        issuesReopened = 0
        issuesModified = 0
        cyclesIntroduced = 0
        cyclesResolved = 0
        netIssueChange = 0
        healthTrend = "stable"
    }

    public var trendSymbol: String {
        switch healthTrend {
        case "improving": "arrow.up.right.circle"
        case "degrading": "arrow.down.right.circle"
        default: "arrow.right.circle"
        }
    }
}

public struct SnapshotDiff: Codable, Sendable, Hashable {
    public var newIssues: [Issue]
    public var closedIssues: [Issue]
    public var removedIssues: [Issue]
    public var reopenedIssues: [Issue]
    public var modifiedIssues: [ModifiedIssue]
    public var newCycles: [[String]]
    public var resolvedCycles: [[String]]
    public var summary: DiffSummary

    private enum CodingKeys: String, CodingKey {
        case summary
        case newIssues = "new_issues"
        case closedIssues = "closed_issues"
        case removedIssues = "removed_issues"
        case reopenedIssues = "reopened_issues"
        case modifiedIssues = "modified_issues"
        case newCycles = "new_cycles"
        case resolvedCycles = "resolved_cycles"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newIssues = try c.decodeIfPresent([Issue].self, forKey: .newIssues) ?? []
        closedIssues = try c.decodeIfPresent([Issue].self, forKey: .closedIssues) ?? []
        removedIssues = try c.decodeIfPresent([Issue].self, forKey: .removedIssues) ?? []
        reopenedIssues = try c.decodeIfPresent([Issue].self, forKey: .reopenedIssues) ?? []
        modifiedIssues = try c.decodeIfPresent([ModifiedIssue].self, forKey: .modifiedIssues) ?? []
        newCycles = try c.decodeIfPresent([[String]].self, forKey: .newCycles) ?? []
        resolvedCycles = try c.decodeIfPresent([[String]].self, forKey: .resolvedCycles) ?? []
        summary = try c.decodeIfPresent(DiffSummary.self, forKey: .summary) ?? DiffSummary()
    }

    public init() {
        newIssues = []
        closedIssues = []
        removedIssues = []
        reopenedIssues = []
        modifiedIssues = []
        newCycles = []
        resolvedCycles = []
        summary = DiffSummary()
    }

    public static let empty = SnapshotDiff()
}

/// A diff against an earlier revision, with the badge each bead earned.
public struct TimeTravelDiff: Codable, Sendable, Hashable {
    public var requestedRevision: String
    public var resolvedRevision: String
    public var shortRevision: String
    public var fromDataHash: String
    public var toDataHash: String
    public var diff: SnapshotDiff
    public var badges: [String: DiffBadge]

    private enum CodingKeys: String, CodingKey {
        case diff, badges
        case requestedRevision = "requested_revision"
        case resolvedRevision = "resolved_revision"
        case shortRevision = "short_revision"
        case fromDataHash = "from_data_hash"
        case toDataHash = "to_data_hash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedRevision = try c.decodeIfPresent(String.self, forKey: .requestedRevision) ?? ""
        resolvedRevision = try c.decodeIfPresent(String.self, forKey: .resolvedRevision) ?? ""
        shortRevision =
            try c.decodeIfPresent(String.self, forKey: .shortRevision)
            ?? String(resolvedRevision.prefix(7))
        fromDataHash = try c.decodeIfPresent(String.self, forKey: .fromDataHash) ?? ""
        toDataHash = try c.decodeIfPresent(String.self, forKey: .toDataHash) ?? ""
        diff = try c.decodeIfPresent(SnapshotDiff.self, forKey: .diff) ?? .empty
        // An unrecognised badge is dropped rather than failing the decode: a
        // missing badge shows the bead as unchanged, which is recoverable,
        // while a thrown error would lose the entire diff.
        let raw = try c.decodeIfPresent([String: String].self, forKey: .badges) ?? [:]
        badges = raw.compactMapValues { DiffBadge(rawValue: $0) }
    }

    public init() {
        requestedRevision = ""
        resolvedRevision = ""
        shortRevision = ""
        fromDataHash = ""
        toDataHash = ""
        diff = .empty
        badges = [:]
    }

    public static let empty = TimeTravelDiff()

    /// True when the two ends really differ.
    public var hasChanges: Bool { diff.summary.totalChanges > 0 }
}
