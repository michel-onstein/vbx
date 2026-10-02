import Foundation

/// How search results are ranked.
///
/// There is no separate "semantic" mode, and the naming is worth being precise
/// about: the vector index is *always* used to find candidates. The mode
/// selects what re-ranks them — the index's own similarity, or bv's hybrid
/// scorer folding in graph metrics.
public enum SearchMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case text
    case hybrid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: "Relevance"
        case .hybrid: "Hybrid"
        }
    }

    public var explanation: String {
        switch self {
        case .text: "Ranked by how well the text matches."
        case .hybrid: "Text relevance re-ranked by centrality, status, impact, priority and recency."
        }
    }
}

/// The relative importance of each ranking factor.
public struct SearchWeights: Codable, Sendable, Hashable {
    public var text: Double
    public var pageRank: Double
    public var status: Double
    public var impact: Double
    public var priority: Double
    public var recency: Double

    private enum CodingKeys: String, CodingKey {
        case text, pagerank, status, impact, priority, recency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(Double.self, forKey: .text) ?? 0
        pageRank = try c.decodeIfPresent(Double.self, forKey: .pagerank) ?? 0
        status = try c.decodeIfPresent(Double.self, forKey: .status) ?? 0
        impact = try c.decodeIfPresent(Double.self, forKey: .impact) ?? 0
        priority = try c.decodeIfPresent(Double.self, forKey: .priority) ?? 0
        recency = try c.decodeIfPresent(Double.self, forKey: .recency) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Every key is written, zeros included: the engine requires all six,
        // and an omitted one is not the same as a zero weight.
        try c.encode(text, forKey: .text)
        try c.encode(pageRank, forKey: .pagerank)
        try c.encode(status, forKey: .status)
        try c.encode(impact, forKey: .impact)
        try c.encode(priority, forKey: .priority)
        try c.encode(recency, forKey: .recency)
    }

    public init(
        text: Double = 0.40, pageRank: Double = 0.20, status: Double = 0.15,
        impact: Double = 0.10, priority: Double = 0.10, recency: Double = 0.05
    ) {
        self.text = text
        self.pageRank = pageRank
        self.status = status
        self.impact = impact
        self.priority = priority
        self.recency = recency
    }

    public var total: Double { text + pageRank + status + impact + priority + recency }

    /// The six factors, for a sliders panel.
    public var factors: [(name: String, value: Double, key: WritableKeyPath<SearchWeights, Double>)] {
        [
            ("Text", text, \.text),
            ("Centrality", pageRank, \.pageRank),
            ("Status", status, \.status),
            ("Impact", impact, \.impact),
            ("Priority", priority, \.priority),
            ("Recency", recency, \.recency),
        ]
    }

    public var asDictionary: [String: Double] {
        [
            "text": text, "pagerank": pageRank, "status": status,
            "impact": impact, "priority": priority, "recency": recency,
        ]
    }
}

/// A named weight set.
public struct SearchPreset: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var weights: SearchWeights

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        weights = try c.decodeIfPresent(SearchWeights.self, forKey: .weights) ?? SearchWeights()
    }

    private enum CodingKeys: String, CodingKey { case name, weights }

    public init(name: String, weights: SearchWeights) {
        self.name = name
        self.weights = weights
    }

    public var displayName: String {
        name.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

public struct SearchPresetList: Codable, Sendable, Hashable {
    public var presets: [SearchPreset]
    public var modes: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = try c.decodeIfPresent([SearchPreset].self, forKey: .presets) ?? []
        modes = try c.decodeIfPresent([String].self, forKey: .modes) ?? []
    }

    private enum CodingKeys: String, CodingKey { case presets, modes }

    public init() {
        presets = []
        modes = []
    }

    public static let empty = SearchPresetList()

    public func weights(named name: String) -> SearchWeights? {
        presets.first { $0.name == name }?.weights
    }
}

/// One ranked result.
public struct SearchHit: Codable, Sendable, Hashable, Identifiable {
    public var issueID: String
    public var score: Double
    public var textScore: Double
    /// Per-factor contributions, present in hybrid mode.
    ///
    /// This is what makes a hybrid ranking auditable rather than a number to
    /// take on trust.
    public var componentScores: [String: Double]

    public var id: String { issueID }

    private enum CodingKeys: String, CodingKey {
        case score
        case issueID = "issue_id"
        case textScore = "text_score"
        case componentScores = "component_scores"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        textScore = try c.decodeIfPresent(Double.self, forKey: .textScore) ?? 0
        componentScores =
            try c.decodeIfPresent([String: Double].self, forKey: .componentScores) ?? [:]
    }

    public init(issueID: String, score: Double) {
        self.issueID = issueID
        self.score = score
        self.textScore = score
        self.componentScores = [:]
    }

    /// The factors that contributed, largest first.
    public var contributions: [(name: String, value: Double)] {
        componentScores
            .map { (name: $0.key, value: $0.value) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
    }
}

/// The result of one query.
public struct SearchResults: Codable, Sendable, Hashable {
    public var query: String
    public var mode: SearchMode
    public var provider: String
    public var dim: Int
    public var indexSize: Int
    public var totalBeads: Int
    public var preset: String
    public var weights: SearchWeights?
    /// The threshold the engine applied, echoed. Nil when none was asked for.
    public var minScore: Double?
    public var results: [SearchHit]

    private enum CodingKeys: String, CodingKey {
        case query, mode, provider, dim, preset, weights, results
        case minScore = "min_score"
        case indexSize = "index_size"
        case totalBeads = "total_beads"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        mode = SearchMode(rawValue: try c.decodeIfPresent(String.self, forKey: .mode) ?? "text")
            ?? .text
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        dim = try c.decodeIfPresent(Int.self, forKey: .dim) ?? 0
        indexSize = try c.decodeIfPresent(Int.self, forKey: .indexSize) ?? 0
        totalBeads = try c.decodeIfPresent(Int.self, forKey: .totalBeads) ?? 0
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? ""
        weights = try? c.decodeIfPresent(SearchWeights.self, forKey: .weights)
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore)
        results = try c.decodeIfPresent([SearchHit].self, forKey: .results) ?? []
    }

    public init() {
        query = ""
        mode = .text
        provider = ""
        dim = 0
        indexSize = 0
        totalBeads = 0
        preset = ""
        results = []
    }

    public static let empty = SearchResults()

    public var isEmpty: Bool { results.isEmpty }

    /// The ids in rank order.
    public var rankedIDs: [String] { results.map(\.issueID) }
}
