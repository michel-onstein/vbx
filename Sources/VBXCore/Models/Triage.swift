import Foundation

/// A scored recommendation: what the engine thinks is worth doing next, and why.
public struct Recommendation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var status: IssueStatus
    public var priority: Int
    public var labels: [String]
    /// Composite impact score — PageRank, betweenness, blocker ratio,
    /// staleness and priority, weighted by the engine.
    public var score: Double
    /// Human-readable next action.
    public var action: String
    /// Why this scored where it did.
    public var reasons: [String]
    public var unblocksIDs: [String]
    public var blockedBy: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, status, priority, labels, score, action, reasons
        case unblocksIDs = "unblocks_ids"
        case blockedBy = "blocked_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = IssueStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "open")
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        unblocksIDs = try c.decodeIfPresent([String].self, forKey: .unblocksIDs) ?? []
        blockedBy = try c.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
    }

    public init(
        id: String, title: String, status: IssueStatus = .open, priority: Int = 0,
        labels: [String] = [], score: Double = 0, action: String = "",
        reasons: [String] = [], unblocksIDs: [String] = [], blockedBy: [String] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.labels = labels
        self.score = score
        self.action = action
        self.reasons = reasons
        self.unblocksIDs = unblocksIDs
        self.blockedBy = blockedBy
    }
}

/// A cheap task that unlocks disproportionate downstream work.
public struct QuickWin: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var score: Double
    public var reason: String
    public var unblocksIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, score, reason
        case unblocksIDs = "unblocks_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        unblocksIDs = try c.decodeIfPresent([String].self, forKey: .unblocksIDs) ?? []
    }
}

/// Something that blocks significant downstream work.
public struct BlockerItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var unblocksCount: Int
    public var unblocksIDs: [String]
    /// Whether this blocker can itself be worked on right now.
    public var actionable: Bool
    public var blockedBy: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, actionable
        case unblocksCount = "unblocks_count"
        case unblocksIDs = "unblocks_ids"
        case blockedBy = "blocked_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        unblocksCount = try c.decodeIfPresent(Int.self, forKey: .unblocksCount) ?? 0
        unblocksIDs = try c.decodeIfPresent([String].self, forKey: .unblocksIDs) ?? []
        actionable = try c.decodeIfPresent(Bool.self, forKey: .actionable) ?? false
        blockedBy = try c.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
    }
}

/// The engine's triage: what to work on next, and what is holding things up.
public struct Triage: Codable, Sendable, Hashable {
    public var recommendations: [Recommendation]
    public var quickWins: [QuickWin]
    public var blockersToClear: [BlockerItem]
    /// The triage feedback this ranking was scored with — bv's `feedback`
    /// block. Absent, as bv omits it, until a verdict has been recorded.
    public var feedback: TriageFeedback?

    private enum CodingKeys: String, CodingKey {
        case recommendations, feedback
        case quickWins = "quick_wins"
        case blockersToClear = "blockers_to_clear"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recommendations = try c.decodeIfPresent([Recommendation].self, forKey: .recommendations) ?? []
        quickWins = try c.decodeIfPresent([QuickWin].self, forKey: .quickWins) ?? []
        blockersToClear = try c.decodeIfPresent([BlockerItem].self, forKey: .blockersToClear) ?? []
        feedback = try c.decodeIfPresent(TriageFeedback.self, forKey: .feedback)
    }

    public init(
        recommendations: [Recommendation] = [], quickWins: [QuickWin] = [],
        blockersToClear: [BlockerItem] = [], feedback: TriageFeedback? = nil
    ) {
        self.recommendations = recommendations
        self.quickWins = quickWins
        self.blockersToClear = blockersToClear
        self.feedback = feedback
    }

    public static let empty = Triage()

    public var isEmpty: Bool {
        recommendations.isEmpty && quickWins.isEmpty && blockersToClear.isEmpty
    }
}

/// bv's triage feedback summary: how many accept / ignore verdicts are on
/// file, and whether the weights they adjust are applied yet.
///
/// Every field is the engine's. `applied` in particular is not derived here
/// from `totalEvents >= minSamples`: the rule is bv's, and so is the number.
public struct TriageFeedback: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Whether the adjusted weights scored this ranking.
    public var applied: Bool
    /// Verdicts needed before the weights apply — bv's MinFeedbackSamples.
    public var minSamples: Int
    public var totalEvents: Int
    public var acceptedCount: Int
    public var ignoredCount: Int

    private enum CodingKeys: String, CodingKey {
        case enabled, applied
        case minSamples = "min_samples"
        case totalEvents = "total_events"
        case acceptedCount = "accepted_count"
        case ignoredCount = "ignored_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        applied = try c.decodeIfPresent(Bool.self, forKey: .applied) ?? false
        minSamples = try c.decodeIfPresent(Int.self, forKey: .minSamples) ?? 0
        totalEvents = try c.decodeIfPresent(Int.self, forKey: .totalEvents) ?? 0
        acceptedCount = try c.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
        ignoredCount = try c.decodeIfPresent(Int.self, forKey: .ignoredCount) ?? 0
    }

    public init(
        enabled: Bool = false, applied: Bool = false, minSamples: Int = 0,
        totalEvents: Int = 0, acceptedCount: Int = 0, ignoredCount: Int = 0
    ) {
        self.enabled = enabled
        self.applied = applied
        self.minSamples = minSamples
        self.totalEvents = totalEvents
        self.acceptedCount = acceptedCount
        self.ignoredCount = ignoredCount
    }
}

/// A verdict on one triage recommendation.
public enum TriageVerdict: String, Codable, Sendable, Hashable {
    /// A good pick: bv's `--feedback-accept`.
    case accept
    /// Not now: bv's `--feedback-ignore`.
    case ignore
}

/// What the engine's feedback methods return: the state after the operation,
/// and bv's own message for the same flag.
public struct TriageFeedbackResult: Codable, Sendable, Hashable {
    public var feedback: TriageFeedback
    public var message: String
    /// The feedback.json read and, for a write, written.
    public var path: String

    private enum CodingKeys: String, CodingKey { case feedback, message, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feedback =
            try c.decodeIfPresent(TriageFeedback.self, forKey: .feedback) ?? TriageFeedback()
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}
