import Foundation

/// How urgent an alert is.
public enum AlertSeverity: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case critical
    case warning
    case info

    public var id: String { rawValue }

    public init(rawValue: String) {
        switch rawValue {
        case "critical": self = .critical
        case "warning": self = .warning
        default: self = .info
        }
    }

    public var displayName: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        }
    }

    public var symbolName: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    /// Ordering for the grouped list: worst first.
    public var rank: Int {
        switch self {
        case .critical: 0
        case .warning: 1
        case .info: 2
        }
    }
}

/// One drift or health alert.
public struct HealthAlert: Codable, Sendable, Hashable, Identifiable {
    public var type: String
    public var severity: AlertSeverity
    public var message: String
    public var baselineValue: Double
    public var currentValue: Double
    public var delta: Double
    public var details: [String]
    public var issueID: String
    public var label: String
    public var detectedAt: Date?
    public var unblocksCount: Int
    public var downstreamPrioritySum: Int
    /// The second bead an alert is about — a potential duplicate's partner.
    /// Empty when the alert names only one.
    public var relatedIssueID: String
    /// The labels of the alert's bead, which `--alert-label` matches along
    /// with ``label``.
    public var labels: [String]
    /// bv's one-line remedy, verbatim. Nil when bv gave none — absent stays
    /// absent rather than becoming an empty line in the panel.
    public var suggestedAction: String?

    /// Stable across reloads: the same condition on the same bead is the same
    /// alert, which is what stops a notification firing again on every reload.
    public var id: String { "\(type)|\(issueID)|\(label)|\(message)" }

    private enum CodingKeys: String, CodingKey {
        case type, severity, message, delta, details, label
        case baselineValue = "baseline_value"
        case currentValue = "current_value"
        case issueID = "issue_id"
        case detectedAt = "detected_at"
        case unblocksCount = "unblocks_count"
        case downstreamPrioritySum = "downstream_priority_sum"
        case relatedIssueID = "related_issue_id"
        case labels
        case suggestedAction = "suggested_action"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        severity = AlertSeverity(
            rawValue: try c.decodeIfPresent(String.self, forKey: .severity) ?? "info")
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        baselineValue = try c.decodeIfPresent(Double.self, forKey: .baselineValue) ?? 0
        currentValue = try c.decodeIfPresent(Double.self, forKey: .currentValue) ?? 0
        delta = try c.decodeIfPresent(Double.self, forKey: .delta) ?? 0
        details = try c.decodeIfPresent([String].self, forKey: .details) ?? []
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        detectedAt = try? c.decodeIfPresent(Date.self, forKey: .detectedAt)
        unblocksCount = try c.decodeIfPresent(Int.self, forKey: .unblocksCount) ?? 0
        downstreamPrioritySum =
            try c.decodeIfPresent(Int.self, forKey: .downstreamPrioritySum) ?? 0
        // The bv 0.25 fields are decoded with `try?`: a shape bv changes later
        // costs the field, never the alert — a dropped alert silently changes
        // the counts the panel shows beside it.
        relatedIssueID = (try? c.decodeIfPresent(String.self, forKey: .relatedIssueID)) ?? ""
        labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
        let action = (try? c.decodeIfPresent(String.self, forKey: .suggestedAction)) ?? nil
        suggestedAction = action?.trimmingCharacters(in: .whitespacesAndNewlines)
        if suggestedAction?.isEmpty == true { suggestedAction = nil }
    }

    public init(
        type: String, severity: AlertSeverity, message: String,
        issueID: String = "", label: String = "", details: [String] = [],
        relatedIssueID: String = "", labels: [String] = [], suggestedAction: String? = nil
    ) {
        self.type = type
        self.severity = severity
        self.message = message
        self.baselineValue = 0
        self.currentValue = 0
        self.delta = 0
        self.details = details
        self.issueID = issueID
        self.label = label
        self.detectedAt = nil
        self.unblocksCount = 0
        self.downstreamPrioritySum = 0
        self.relatedIssueID = relatedIssueID
        self.labels = labels
        self.suggestedAction = suggestedAction
    }

    /// The alert type as prose.
    public var typeDisplayName: String { Self.displayName(forType: type) }

    /// The SF Symbol for the alert type.
    public var typeSymbolName: String { Self.symbolName(forType: type) }

    /// Every alert type bv 0.25.2 emits, with its name and symbol. The type
    /// set is open: one missing here still decodes and still shows, under
    /// ``fallbackSymbolName`` and a name made from its raw value.
    public static let knownTypes: [String: (name: String, symbol: String)] = [
        "new_cycle": ("New Cycle", "arrow.triangle.2.circlepath"),
        "pagerank_change": ("PageRank Change", "chart.line.uptrend.xyaxis"),
        "density_growth": ("Density Growth", "circle.grid.cross"),
        "node_count_change": ("Node Count Change", "circle.hexagongrid"),
        "edge_count_change": ("Edge Count Change", "point.3.connected.trianglepath.dotted"),
        "blocked_increase": ("Blocked Increase", "hand.raised"),
        "actionable_change": ("Actionable Change", "checklist"),
        "stale_issue": ("Stale Issue", "clock.badge.exclamationmark"),
        "velocity_drop": ("Velocity Drop", "speedometer"),
        "blocking_cascade": ("Blocking Cascade", "square.stack.3d.down.right"),
        "high_impact_unblock": ("High-Impact Unblock", "bolt"),
        "abandoned_claim": ("Abandoned Claim", "person.crop.circle.badge.questionmark"),
        "potential_duplicate": ("Potential Duplicate", "doc.on.doc"),
        "priority_mismatch": ("Priority Mismatch", "arrow.up.arrow.down"),
        "scope_creep": ("Scope Creep", "arrow.up.left.and.arrow.down.right"),
    ]

    /// The symbol for an alert type vbx does not know yet.
    public static let fallbackSymbolName = "bell"

    /// An alert type as prose — also what the type picker lists.
    public static func displayName(forType type: String) -> String {
        knownTypes[type]?.name ?? type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public static func symbolName(forType type: String) -> String {
        knownTypes[type]?.symbol ?? fallbackSymbolName
    }

    /// The label and the bead's labels, in order and without repeats — the
    /// set `--alert-label` matches exactly, so it is what the panel shows.
    public var allLabels: [String] {
        var seen = Set<String>()
        return ([label] + labels).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// True when the alert carries a before-and-after worth showing.
    ///
    /// A delta of zero on an issue-derived alert is not a measurement, it is
    /// the absence of one — showing "0 → 0" would invent a comparison.
    public var hasDelta: Bool {
        baselineValue != 0 || currentValue != 0
    }
}

public struct AlertSummary: Codable, Sendable, Hashable {
    public var total: Int
    public var critical: Int
    public var warning: Int
    public var info: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        critical = try c.decodeIfPresent(Int.self, forKey: .critical) ?? 0
        warning = try c.decodeIfPresent(Int.self, forKey: .warning) ?? 0
        info = try c.decodeIfPresent(Int.self, forKey: .info) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case total, critical, warning, info }

    public init() {
        total = 0
        critical = 0
        warning = 0
        info = 0
    }
}

/// The saved baseline drift is measured from.
public struct BaselineInfo: Codable, Sendable, Hashable {
    public var exists: Bool
    public var path: String
    public var createdAt: Date?
    public var commitSHA: String
    public var commitMessage: String
    public var branch: String
    public var description: String
    public var summary: String

    private enum CodingKeys: String, CodingKey {
        case exists, path, branch, description, summary
        case createdAt = "created_at"
        case commitSHA = "commit_sha"
        case commitMessage = "commit_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA) ?? ""
        commitMessage = try c.decodeIfPresent(String.self, forKey: .commitMessage) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }

    public init() {
        exists = false
        path = ""
        commitSHA = ""
        commitMessage = ""
        branch = ""
        description = ""
        summary = ""
    }

    public static let empty = BaselineInfo()

    public var shortSHA: String { String(commitSHA.prefix(7)) }
}

/// The alerts panel's whole payload.
public struct AlertReport: Codable, Sendable, Hashable {
    public var alerts: [HealthAlert]
    public var hasBaseline: Bool
    public var summary: AlertSummary

    private enum CodingKeys: String, CodingKey {
        case alerts, summary
        case hasBaseline = "has_baseline"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alerts = try c.decodeIfPresent([HealthAlert].self, forKey: .alerts) ?? []
        hasBaseline = try c.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? false
        summary = try c.decodeIfPresent(AlertSummary.self, forKey: .summary) ?? AlertSummary()
    }

    public init(alerts: [HealthAlert] = [], hasBaseline: Bool = false) {
        self.alerts = alerts
        self.hasBaseline = hasBaseline
        self.summary = AlertSummary()
    }

    public static let empty = AlertReport()

    /// Alerts grouped by severity, worst group first, with empty groups
    /// omitted so the panel shows no headings for nothing.
    public var grouped: [(severity: AlertSeverity, alerts: [HealthAlert])] {
        AlertSeverity.allCases
            .sorted { $0.rank < $1.rank }
            .map { severity in
                (severity, alerts.filter { $0.severity == severity })
            }
            .filter { !$0.1.isEmpty }
    }

    /// Every distinct alert type present, for the filter menu.
    public var types: [String] {
        Array(Set(alerts.map(\.type))).sorted()
    }

    /// Every distinct label mentioned, for the filter menu — the alert's own
    /// label and its bead's labels, since the engine's `alert_label` filter
    /// matches either.
    public var labels: [String] {
        Array(Set(alerts.flatMap(\.allLabels))).sorted()
    }
}
