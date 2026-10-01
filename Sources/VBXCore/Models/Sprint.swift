import Foundation

/// A time-boxed period of work.
public struct Sprint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var startDate: Date?
    public var endDate: Date?
    public var beadIDs: [String]
    public var velocityTarget: Double

    private enum CodingKeys: String, CodingKey {
        case id, name
        case startDate = "start_date"
        case endDate = "end_date"
        case beadIDs = "bead_ids"
        case velocityTarget = "velocity_target"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
        beadIDs = try c.decodeIfPresent([String].self, forKey: .beadIDs) ?? []
        velocityTarget = try c.decodeIfPresent(Double.self, forKey: .velocityTarget) ?? 0
    }

    public init(
        id: String, name: String, startDate: Date? = nil, endDate: Date? = nil,
        beadIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.beadIDs = beadIDs
        self.velocityTarget = 0
    }

    /// True when today falls inside the sprint.
    public var isActive: Bool {
        guard let startDate, let endDate else { return false }
        let now = Date()
        return !now.isBefore(startDate) && !now.isAfter(endDate)
    }

    public var displayName: String { name.isEmpty ? id : name }
}

extension Date {
    fileprivate func isBefore(_ other: Date) -> Bool { self < other }
    fileprivate func isAfter(_ other: Date) -> Bool { self > other }
}

/// The sprint list.
public struct SprintList: Codable, Sendable, Hashable {
    public var sprints: [Sprint]
    public var sprintCount: Int

    private enum CodingKeys: String, CodingKey {
        case sprints
        case sprintCount = "sprint_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sprints = try c.decodeIfPresent([Sprint].self, forKey: .sprints) ?? []
        sprintCount = try c.decodeIfPresent(Int.self, forKey: .sprintCount) ?? sprints.count
    }

    public init(sprints: [Sprint] = []) {
        self.sprints = sprints
        self.sprintCount = sprints.count
    }

    public static let empty = SprintList()

    public var active: Sprint? { sprints.first(where: \.isActive) }
}

/// One point on a burndown line.
public struct BurndownPoint: Codable, Sendable, Hashable, Identifiable {
    public var date: Date
    public var remaining: Int
    public var completed: Int

    public var id: Date { date }

    private enum CodingKeys: String, CodingKey { case date, remaining, completed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil ?? .distantPast
        remaining = try c.decodeIfPresent(Int.self, forKey: .remaining) ?? 0
        completed = try c.decodeIfPresent(Int.self, forKey: .completed) ?? 0
    }

    public init(date: Date, remaining: Int, completed: Int = 0) {
        self.date = date
        self.remaining = remaining
        self.completed = completed
    }
}

/// One sprint bead bv's at-risk detector flagged, and why.
public struct AtRiskItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public var priority: Int
    /// The engine's signal names — `blocked_too_long`, `no_activity`,
    /// `critical_blocked`, `blockers_not_closing`. Kept as strings so a signal
    /// a later engine adds is shown rather than dropped.
    public var signals: [String]
    /// The earliest instant behind any of the signals.
    public var since: Date?
    /// The engine's explanation of each signal, in a sentence.
    public var detail: String

    private enum CodingKeys: String, CodingKey {
        case id, title, status, priority, signals, since, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 2
        signals = try c.decodeIfPresent([String].self, forKey: .signals) ?? []
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    public init(
        id: String, title: String = "", status: String = "open", priority: Int = 2,
        signals: [String], since: Date? = nil, detail: String = ""
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.signals = signals
        self.since = since
        self.detail = detail
    }

    /// A signal's name for display. Formatting only: an unknown signal is
    /// shown as the engine spelled it.
    public static func label(for signal: String) -> String {
        switch signal {
        case "blocked_too_long": "Blocked too long"
        case "no_activity": "No activity"
        case "critical_blocked": "Critical, blocked"
        case "blockers_not_closing": "Blockers not closing"
        default: signal.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// A bead joining or leaving a sprint after it was planned, read from the
/// sprint file's git history.
public struct ScopeChange: Codable, Sendable, Hashable, Identifiable {
    public var date: Date
    public var issueID: String
    public var issueTitle: String
    /// `added` or `removed`.
    public var action: String

    public var id: String { "\(date.timeIntervalSince1970)-\(action)-\(issueID)" }
    public var isAddition: Bool { action == "added" }

    private enum CodingKeys: String, CodingKey {
        case date, action
        case issueID = "issue_id"
        case issueTitle = "issue_title"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil ?? .distantPast
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        issueTitle = try c.decodeIfPresent(String.self, forKey: .issueTitle) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
    }

    public init(date: Date, issueID: String, issueTitle: String = "", action: String) {
        self.date = date
        self.issueID = issueID
        self.issueTitle = issueTitle
        self.action = action
    }
}

/// A sprint's burndown, with the ideal line and a projection.
public struct Burndown: Codable, Sendable, Hashable {
    public var sprintID: String
    public var sprintName: String
    public var startDate: Date?
    public var endDate: Date?
    public var totalDays: Int
    public var elapsedDays: Int
    public var remainingDays: Int
    public var totalIssues: Int
    public var completedIssues: Int
    public var remainingIssues: Int
    public var idealBurnRate: Double
    public var actualBurnRate: Double
    /// Absent when there is no rate to extrapolate from.
    public var projectedComplete: Date?
    public var onTrack: Bool
    public var dailyPoints: [BurndownPoint]
    /// Scope-aware: it bends where beads joined or left the sprint.
    public var idealLine: [BurndownPoint]
    /// Sprint beads bv's detector flags. Nil when the engine did not report
    /// it — unknown, which is not the same as the empty list's "none".
    public var atRisk: [AtRiskItem]?
    /// Beads that joined or left mid-sprint, oldest first. Empty when the
    /// sprint never changed or the workspace has no history to read.
    public var scopeChanges: [ScopeChange]

    private enum CodingKeys: String, CodingKey {
        case sprintID = "sprint_id"
        case sprintName = "sprint_name"
        case startDate = "start_date"
        case endDate = "end_date"
        case totalDays = "total_days"
        case elapsedDays = "elapsed_days"
        case remainingDays = "remaining_days"
        case totalIssues = "total_issues"
        case completedIssues = "completed_issues"
        case remainingIssues = "remaining_issues"
        case idealBurnRate = "ideal_burn_rate"
        case actualBurnRate = "actual_burn_rate"
        case projectedComplete = "projected_complete"
        case onTrack = "on_track"
        case dailyPoints = "daily_points"
        case idealLine = "ideal_line"
        case atRisk = "at_risk"
        case scopeChanges = "scope_changes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sprintID = try c.decodeIfPresent(String.self, forKey: .sprintID) ?? ""
        sprintName = try c.decodeIfPresent(String.self, forKey: .sprintName) ?? ""
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
        totalDays = try c.decodeIfPresent(Int.self, forKey: .totalDays) ?? 0
        elapsedDays = try c.decodeIfPresent(Int.self, forKey: .elapsedDays) ?? 0
        remainingDays = try c.decodeIfPresent(Int.self, forKey: .remainingDays) ?? 0
        totalIssues = try c.decodeIfPresent(Int.self, forKey: .totalIssues) ?? 0
        completedIssues = try c.decodeIfPresent(Int.self, forKey: .completedIssues) ?? 0
        remainingIssues = try c.decodeIfPresent(Int.self, forKey: .remainingIssues) ?? 0
        idealBurnRate = try c.decodeIfPresent(Double.self, forKey: .idealBurnRate) ?? 0
        actualBurnRate = try c.decodeIfPresent(Double.self, forKey: .actualBurnRate) ?? 0
        projectedComplete = try? c.decodeIfPresent(Date.self, forKey: .projectedComplete)
        onTrack = try c.decodeIfPresent(Bool.self, forKey: .onTrack) ?? true
        dailyPoints = try c.decodeIfPresent([BurndownPoint].self, forKey: .dailyPoints) ?? []
        idealLine = try c.decodeIfPresent([BurndownPoint].self, forKey: .idealLine) ?? []
        atRisk = try c.decodeIfPresent([AtRiskItem].self, forKey: .atRisk)
        scopeChanges = try c.decodeIfPresent([ScopeChange].self, forKey: .scopeChanges) ?? []
    }

    public init() {
        sprintID = ""
        sprintName = ""
        totalDays = 0
        elapsedDays = 0
        remainingDays = 0
        totalIssues = 0
        completedIssues = 0
        remainingIssues = 0
        idealBurnRate = 0
        actualBurnRate = 0
        onTrack = true
        dailyPoints = []
        idealLine = []
        atRisk = nil
        scopeChanges = []
    }

    public static let empty = Burndown()

    public var isLoaded: Bool { !sprintID.isEmpty }

    /// Fraction of the sprint's work that is done.
    public var completion: Double {
        totalIssues > 0 ? Double(completedIssues) / Double(totalIssues) : 0
    }

    /// How far ahead or behind the ideal the sprint is, in beads.
    ///
    /// Nil before the sprint starts, when there is nothing to compare.
    public var aheadBy: Int? {
        guard elapsedDays > 0, elapsedDays <= idealLine.count else { return nil }
        let idealRemaining = idealLine[elapsedDays - 1].remaining
        return idealRemaining - remainingIssues
    }

    /// Why the sprint is or is not on track, in a sentence.
    public var verdict: String {
        if totalIssues == 0 { return "This sprint has no beads." }
        if remainingIssues == 0 { return "Every bead is closed." }
        if elapsedDays == 0 { return "The sprint has not started yet." }
        if actualBurnRate == 0 {
            return "Nothing has closed yet, so there is no rate to project from."
        }
        if let projected = projectedComplete {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            let date = formatter.string(from: projected)
            return onTrack
                ? "At the current rate this finishes around \(date), inside the sprint."
                : "At the current rate this finishes around \(date), after the sprint ends."
        }
        return onTrack ? "On track." : "Behind."
    }
}

/// One bead holding up several others.
public struct CapacityBottleneck: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var blocksCount: Int
    public var blocks: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, blocks
        case blocksCount = "blocks_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        blocksCount = try c.decodeIfPresent(Int.self, forKey: .blocksCount) ?? 0
        blocks = try c.decodeIfPresent([String].self, forKey: .blocks) ?? []
    }
}

/// How long the open work takes with a given number of agents.
public struct Capacity: Codable, Sendable, Hashable {
    public var agents: Int
    public var label: String
    public var openIssueCount: Int
    public var totalMinutes: Int
    public var totalDays: Double
    public var serialMinutes: Int
    public var parallelMinutes: Int
    public var parallelizablePct: Double
    public var effectiveMinutes: Int
    public var estimatedDays: Double
    public var criticalPath: [String]
    public var actionable: [String]
    public var bottlenecks: [CapacityBottleneck]

    private enum CodingKeys: String, CodingKey {
        case agents, label, bottlenecks, actionable
        case openIssueCount = "open_issue_count"
        case totalMinutes = "total_minutes"
        case totalDays = "total_days"
        case serialMinutes = "serial_minutes"
        case parallelMinutes = "parallel_minutes"
        case parallelizablePct = "parallelizable_pct"
        case effectiveMinutes = "effective_minutes"
        case estimatedDays = "estimated_days"
        case criticalPath = "critical_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = try c.decodeIfPresent(Int.self, forKey: .agents) ?? 1
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        openIssueCount = try c.decodeIfPresent(Int.self, forKey: .openIssueCount) ?? 0
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes) ?? 0
        totalDays = try c.decodeIfPresent(Double.self, forKey: .totalDays) ?? 0
        serialMinutes = try c.decodeIfPresent(Int.self, forKey: .serialMinutes) ?? 0
        parallelMinutes = try c.decodeIfPresent(Int.self, forKey: .parallelMinutes) ?? 0
        parallelizablePct = try c.decodeIfPresent(Double.self, forKey: .parallelizablePct) ?? 0
        effectiveMinutes = try c.decodeIfPresent(Int.self, forKey: .effectiveMinutes) ?? 0
        estimatedDays = try c.decodeIfPresent(Double.self, forKey: .estimatedDays) ?? 0
        criticalPath = try c.decodeIfPresent([String].self, forKey: .criticalPath) ?? []
        actionable = try c.decodeIfPresent([String].self, forKey: .actionable) ?? []
        bottlenecks =
            try c.decodeIfPresent([CapacityBottleneck].self, forKey: .bottlenecks) ?? []
    }

    public init() {
        agents = 1
        label = ""
        openIssueCount = 0
        totalMinutes = 0
        totalDays = 0
        serialMinutes = 0
        parallelMinutes = 0
        parallelizablePct = 0
        effectiveMinutes = 0
        estimatedDays = 0
        criticalPath = []
        actionable = []
        bottlenecks = []
    }

    public static let empty = Capacity()
}
