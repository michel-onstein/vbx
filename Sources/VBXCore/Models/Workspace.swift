import Foundation

/// Where a workspace's bead data actually came from.
public enum SourceKind: String, Codable, Sendable {
    case jsonl
    case sqlite

    public var displayName: String {
        switch self {
        case .jsonl: "JSONL"
        case .sqlite: "SQLite"
        }
    }
}

/// What the engine reports after opening a workspace.
public struct WorkspaceInfo: Codable, Sendable, Hashable {
    /// The file actually read, after discovery.
    public var source: String
    public var kind: SourceKind
    public var issueCount: Int
    /// SHA-256 over the sorted issue set. Doubles as the reload gate and the
    /// value shown in the status bar for cross-checking against `bv`.
    public var dataHash: String
    /// Non-fatal loader complaints: malformed lines, empty files, and so on.
    public var warnings: [String]
    public var loadedAt: Date?
    /// Set by `reload`: false means the data hash was unchanged and nothing was
    /// re-analysed, so the UI can skip republishing.
    public var changed: Bool
    /// The directories the engine reads from, which is what live reload must
    /// watch. For a multi-repository workspace that is every member's beads
    /// directory and the root `.beads`, not just the `.bv/` holding the
    /// source — see ``watchDirectories`` and vbx-zot.
    public var watchPaths: [String]
    /// The git directories of a multi-repository workspace's members.
    ///
    /// A member is normally its own repository, so a commit there moves a
    /// `HEAD` the watch on the root repository never sees, and its uncommitted
    /// marks would never clear. Kept apart from ``watchPaths`` because a commit
    /// changes no bead: it calls for the marks to be recomputed, which the
    /// hash-gated reload would skip (vbx-d1c). Empty for a single repository,
    /// whose git directory the store finds itself.
    public var gitWatchPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case source, kind, warnings, changed
        case issueCount = "issue_count"
        case dataHash = "data_hash"
        case loadedAt = "loaded_at"
        case watchPaths = "watch_paths"
        case gitWatchPaths = "git_watch_paths"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        kind = SourceKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "jsonl") ?? .jsonl
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        dataHash = try c.decodeIfPresent(String.self, forKey: .dataHash) ?? ""
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        // Absent on a plain open; only reload reports it.
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? true
        watchPaths = try c.decodeIfPresent([String].self, forKey: .watchPaths) ?? []
        gitWatchPaths = try c.decodeIfPresent([String].self, forKey: .gitWatchPaths) ?? []
        if let raw = try c.decodeIfPresent(String.self, forKey: .loadedAt) {
            loadedAt = ISO8601DateFormatter().date(from: raw)
        }
    }

    public init(
        source: String, kind: SourceKind, issueCount: Int,
        dataHash: String, warnings: [String] = [], loadedAt: Date? = nil,
        changed: Bool = true, watchPaths: [String] = [], gitWatchPaths: [String] = []
    ) {
        self.gitWatchPaths = gitWatchPaths
        self.source = source
        self.kind = kind
        self.issueCount = issueCount
        self.dataHash = dataHash
        self.warnings = warnings
        self.loadedAt = loadedAt
        self.changed = changed
        self.watchPaths = watchPaths
    }

    /// What live reload watches: the engine's list, or the source's directory
    /// when it reported none.
    ///
    /// The engine owns the list because it owns discovery — which members a
    /// workspace has, and where each one's data actually lives once a redirect
    /// is followed. Re-parsing `workspace.yaml` here would be a second copy of
    /// those rules. The fallback covers a payload from before the field.
    public var watchDirectories: [String] {
        if !watchPaths.isEmpty { return watchPaths }
        guard !source.isEmpty else { return [] }
        return [URL(fileURLWithPath: source).deletingLastPathComponent().path]
    }

    /// Directory shown in the window title.
    public var displayName: String {
        let url = URL(fileURLWithPath: source)
        // .../<project>/.beads/issues.jsonl -> <project>
        let beadsDir = url.deletingLastPathComponent()
        if beadsDir.lastPathComponent == ".beads" {
            return beadsDir.deletingLastPathComponent().lastPathComponent
        }
        return beadsDir.lastPathComponent
    }

    /// Short form of the data hash for the status bar.
    public var shortHash: String { String(dataHash.prefix(8)) }
}

/// The formats bv 0.25's `--export-format` accepts.
///
/// Which combinations are valid is the engine's rule (bv's
/// `ResolveReportOptions`); the properties here only let the export sheet
/// offer the controls that rule leaves open, and the engine still rejects
/// anything else.
public enum ReportFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case markdown, json, csv, mermaid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        case .csv: "CSV"
        case .mermaid: "Mermaid"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .json: "json"
        case .csv: "csv"
        case .mermaid: "mmd"
        }
    }

    /// The graph setting this format forces, or nil when it is a choice: a
    /// CSV row has nowhere to put a graph, and a Mermaid export *is* one.
    public var fixedGraph: Bool? {
        switch self {
        case .csv: false
        case .mermaid: true
        case .markdown, .json: nil
        }
    }

    /// Only the Markdown report takes a custom template.
    public var acceptsTemplate: Bool { self == .markdown }
}

/// What to export: bv's `--export-format`, `--export-include-graph` and
/// `--export-template`, plus the recipe and label scope that select the beads.
///
/// A nil field is "not given", so a recipe's `export:` default applies; an
/// explicit `false` or empty template overrides it, exactly as in bv.
public struct ReportRequest: Sendable, Hashable {
    public var format: ReportFormat?
    public var includeGraph: Bool?
    public var template: String?
    public var recipe: String?
    public var label: String?
    /// Replaces bv's fixed "Beads Export" heading. bv has no flag for it.
    public var title: String?

    public init(
        format: ReportFormat? = nil, includeGraph: Bool? = nil, template: String? = nil,
        recipe: String? = nil, label: String? = nil, title: String? = nil
    ) {
        self.format = format
        self.includeGraph = includeGraph
        self.template = template
        self.recipe = recipe
        self.label = label
        self.title = title
    }
}

/// A rendered report, and the options it was rendered with once a recipe's
/// defaults were applied.
public struct ReportExport: Codable, Sendable, Hashable {
    public var content: String
    public var format: String
    public var includeGraph: Bool
    public var template: String
    public var title: String
    public var issueCount: Int
    public var bytes: Int
    /// Non-empty when the engine also wrote the file itself.
    public var path: String

    private enum CodingKeys: String, CodingKey {
        case content, format, template, title, bytes, path
        case includeGraph = "include_graph"
        case issueCount = "issue_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        includeGraph = try c.decodeIfPresent(Bool.self, forKey: .includeGraph) ?? false
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

/// One actionable item within a track, as the engine reports it.
public struct PlanItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var priority: Int
    public var status: IssueStatus
    /// Issues that become actionable once this one is done.
    public var unblocks: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, priority, status, unblocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        status = IssueStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "open")
        unblocks = try c.decodeIfPresent([String].self, forKey: .unblocks) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(priority, forKey: .priority)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(unblocks, forKey: .unblocks)
    }

    public init(id: String, title: String, priority: Int = 0, status: IssueStatus = .open, unblocks: [String] = []) {
        self.id = id
        self.title = title
        self.priority = priority
        self.status = status
        self.unblocks = unblocks
    }
}

/// One parallelisable stream of actionable work — a connected component of the
/// actionable subgraph, so two people in different tracks cannot collide.
public struct ExecutionTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var items: [PlanItem]
    /// Why the engine grouped these together.
    public var reason: String

    private enum CodingKeys: String, CodingKey {
        case id = "track_id"
        case items
        case reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        items = try c.decodeIfPresent([PlanItem].self, forKey: .items) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(items, forKey: .items)
        try c.encode(reason, forKey: .reason)
    }

    public init(id: String, items: [PlanItem], reason: String = "") {
        self.id = id
        self.items = items
        self.reason = reason
    }
}

/// The engine's execution plan: what can be worked on now, and in parallel.
public struct ExecutionPlan: Codable, Sendable, Hashable {
    public var tracks: [ExecutionTrack]
    public var totalActionable: Int
    public var totalBlocked: Int
    /// The single highest-impact item and why.
    public var highestImpact: String
    public var impactReason: String
    public var unblocksCount: Int

    private enum CodingKeys: String, CodingKey {
        case tracks, summary
        case totalActionable = "total_actionable"
        case totalBlocked = "total_blocked"
    }

    private enum SummaryKeys: String, CodingKey {
        case highestImpact = "highest_impact"
        case impactReason = "impact_reason"
        case unblocksCount = "unblocks_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decodeIfPresent([ExecutionTrack].self, forKey: .tracks) ?? []
        totalActionable = try c.decodeIfPresent(Int.self, forKey: .totalActionable) ?? 0
        totalBlocked = try c.decodeIfPresent(Int.self, forKey: .totalBlocked) ?? 0

        if let s = try? c.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary) {
            highestImpact = try s.decodeIfPresent(String.self, forKey: .highestImpact) ?? ""
            impactReason = try s.decodeIfPresent(String.self, forKey: .impactReason) ?? ""
            unblocksCount = try s.decodeIfPresent(Int.self, forKey: .unblocksCount) ?? 0
        } else {
            highestImpact = ""
            impactReason = ""
            unblocksCount = 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(totalActionable, forKey: .totalActionable)
        try c.encode(totalBlocked, forKey: .totalBlocked)
        var s = c.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary)
        try s.encode(highestImpact, forKey: .highestImpact)
        try s.encode(impactReason, forKey: .impactReason)
        try s.encode(unblocksCount, forKey: .unblocksCount)
    }

    public init(
        tracks: [ExecutionTrack], totalActionable: Int = 0, totalBlocked: Int = 0,
        highestImpact: String = "", impactReason: String = "", unblocksCount: Int = 0
    ) {
        self.tracks = tracks
        self.totalActionable = totalActionable
        self.totalBlocked = totalBlocked
        self.highestImpact = highestImpact
        self.impactReason = impactReason
        self.unblocksCount = unblocksCount
    }

    public static let empty = ExecutionPlan(tracks: [])
}

/// What the engine reports about a path it has *not* opened.
///
/// The Open panel needs an answer for every folder the user browses past, and
/// it needs it before they commit to one. Asking the engine — rather than
/// checking for a `.beads` directory in Swift — is what keeps the panel and the
/// loader from disagreeing: a second predicate written here would be a copy of
/// discovery's rules that drifts the moment they change.
public struct ProbeResult: Codable, Sendable, Hashable {
    public var path: String
    /// Whether ``BeadsEngine/open(path:skipPhase2:)`` would succeed.
    public var canOpen: Bool
    /// `workspace`, `jsonl` or `sqlite` when openable, otherwise empty.
    public var kind: String
    /// The file that would actually be read.
    public var source: String
    /// Why it was refused, for a tooltip or an error.
    public var reason: String

    private enum CodingKeys: String, CodingKey {
        case path, kind, source, reason
        case canOpen = "can_open"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        // Absent reads as "no" — a probe that failed to answer must never
        // offer a folder the loader will then refuse.
        canOpen = try c.decodeIfPresent(Bool.self, forKey: .canOpen) ?? false
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    public init(
        path: String, canOpen: Bool, kind: String = "", source: String = "", reason: String = ""
    ) {
        self.path = path
        self.canOpen = canOpen
        self.kind = kind
        self.source = source
        self.reason = reason
    }
}
