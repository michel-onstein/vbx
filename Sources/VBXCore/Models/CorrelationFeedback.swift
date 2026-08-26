import Foundation

/// One commit's unified diff.
public struct CommitPatch: Codable, Sendable, Hashable, Identifiable {
    public var sha: String
    public var path: String
    public var patch: String
    public var bytes: Int

    /// A diff is identified by what it is a diff of — which is what lets the
    /// patch sheet be driven by the patch itself rather than by a flag beside
    /// it. Computed, so it is not part of the wire format.
    public var id: String { "\(sha):\(path)" }

    private enum CodingKeys: String, CodingKey { case sha, path, patch, bytes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
    }

    public init(sha: String, path: String = "", patch: String = "") {
        self.sha = sha
        self.path = path
        self.patch = patch
        self.bytes = patch.utf8.count
    }

    /// The diff split into lines tagged by what they represent, so the view
    /// can colour them without re-parsing.
    public var lines: [PatchLine] {
        patch.components(separatedBy: .newlines).enumerated().map { index, text in
            PatchLine(id: index, text: text, kind: PatchLine.classify(text))
        }
    }
}

/// One line of a unified diff.
public struct PatchLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case added, removed, hunk, meta, context
    }

    public let id: Int
    public let text: String
    public let kind: Kind

    /// Classifies a diff line.
    ///
    /// Order matters: `+++` and `---` are file headers, not an added and a
    /// removed line, and checking the single-character prefixes first would
    /// colour every diff's header green and red.
    public static func classify(_ text: String) -> Kind {
        if text.hasPrefix("+++") || text.hasPrefix("---") { return .meta }
        if text.hasPrefix("diff ") || text.hasPrefix("index ")
            || text.hasPrefix("new file") || text.hasPrefix("deleted file")
            || text.hasPrefix("rename ")
        {
            return .meta
        }
        if text.hasPrefix("@@") { return .hunk }
        if text.hasPrefix("+") { return .added }
        if text.hasPrefix("-") { return .removed }
        return .context
    }
}

/// A human verdict on one commit-to-bead link.
public struct CorrelationFeedback: Codable, Sendable, Hashable, Identifiable {
    public var commitSHA: String
    public var beadID: String
    public var feedbackAt: Date?
    public var feedbackBy: String
    /// `confirm`, `reject` or `ignore`.
    public var type: String
    public var reason: String
    /// What the engine believed before the verdict.
    public var originalConfidence: Double

    public var id: String { "\(commitSHA)-\(beadID)" }

    private enum CodingKeys: String, CodingKey {
        case type, reason
        case commitSHA = "commit_sha"
        case beadID = "bead_id"
        case feedbackAt = "feedback_at"
        case feedbackBy = "feedback_by"
        case originalConfidence = "original_conf"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA) ?? ""
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        feedbackAt = try? c.decodeIfPresent(Date.self, forKey: .feedbackAt)
        feedbackBy = try c.decodeIfPresent(String.self, forKey: .feedbackBy) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        originalConfidence = try c.decodeIfPresent(Double.self, forKey: .originalConfidence) ?? 0
    }
}

/// How well the engine's correlations have been holding up.
public struct FeedbackStats: Codable, Sendable, Hashable {
    public var totalFeedback: Int
    public var confirmed: Int
    public var rejected: Int
    public var ignored: Int
    public var accuracyRate: Double
    public var avgConfirmConfidence: Double
    public var avgRejectConfidence: Double

    private enum CodingKeys: String, CodingKey {
        case confirmed, rejected, ignored
        case totalFeedback = "total_feedback"
        case accuracyRate = "accuracy_rate"
        case avgConfirmConfidence = "avg_confirm_conf"
        case avgRejectConfidence = "avg_reject_conf"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalFeedback = try c.decodeIfPresent(Int.self, forKey: .totalFeedback) ?? 0
        confirmed = try c.decodeIfPresent(Int.self, forKey: .confirmed) ?? 0
        rejected = try c.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
        ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
        accuracyRate = try c.decodeIfPresent(Double.self, forKey: .accuracyRate) ?? 0
        avgConfirmConfidence = try c.decodeIfPresent(Double.self, forKey: .avgConfirmConfidence) ?? 0
        avgRejectConfidence = try c.decodeIfPresent(Double.self, forKey: .avgRejectConfidence) ?? 0
    }

    public init() {
        totalFeedback = 0
        confirmed = 0
        rejected = 0
        ignored = 0
        accuracyRate = 0
        avgConfirmConfidence = 0
        avgRejectConfidence = 0
    }
}

public struct CorrelationFeedbackReport: Codable, Sendable, Hashable {
    public var feedback: [CorrelationFeedback]
    public var stats: FeedbackStats

    private enum CodingKeys: String, CodingKey { case feedback, stats }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feedback = try c.decodeIfPresent([CorrelationFeedback].self, forKey: .feedback) ?? []
        stats = try c.decodeIfPresent(FeedbackStats.self, forKey: .stats) ?? FeedbackStats()
    }

    public init() {
        feedback = []
        stats = FeedbackStats()
    }

    public static let empty = CorrelationFeedbackReport()

    /// The verdict on one link, if any has been recorded.
    public func verdict(sha: String, beadID: String) -> CorrelationFeedback? {
        feedback.first { $0.commitSHA == sha && $0.beadID == beadID }
    }
}

/// The result of recording one verdict.
public struct CorrelationVerdict: Codable, Sendable, Hashable {
    public var sha: String
    public var beadID: String
    public var type: String
    public var originalConfidence: Double
    public var stats: FeedbackStats

    private enum CodingKeys: String, CodingKey {
        case sha, type, stats
        case beadID = "bead_id"
        case originalConfidence = "original_conf"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        originalConfidence = try c.decodeIfPresent(Double.self, forKey: .originalConfidence) ?? 0
        stats = try c.decodeIfPresent(FeedbackStats.self, forKey: .stats) ?? FeedbackStats()
    }
}
