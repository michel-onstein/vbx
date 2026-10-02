import VBXCore
import VBXEngine
import Foundation

// vbx-cli speaks bv's robot protocol.
//
// It links the same engine archive the app does, so any output here is
// produced by exactly the code path the GUI uses — which is the point: a
// number that differs between the two would mean one of them is wrong, and
// there would be no way to tell which.
//
// Two contracts are inherited from bv deliberately:
//
//   - **stdout carries structured data only.** Diagnostics and errors go to
//     stderr, so a caller can pipe stdout into a parser without filtering.
//   - **Exit codes are 0, 1 and 2.** 0 succeeded, 1 failed, 2 means the
//     arguments were wrong.

// MARK: - Robot command table

/// What `--label` and `--recipe` do to a command. bv 0.25.2 applies both as
/// one global scope (`scopeLoadedIssues`) after it loads issues and before
/// any post-load handler runs, so the rule follows from where bv answers the
/// command — read from `cmd/bv`, never assumed.
enum ScopeRule {
    /// bv answers before it resolves a recipe or loads issues (the recipe
    /// list, triage feedback), or the command is vbx's own: both flags are
    /// ignored, as bv ignores them.
    case ignored
    /// bv's global scope: the engine answers over the label's subgraph,
    /// narrowed to what the recipe selects, and says so in the envelope.
    /// Alerts and capacity take a filter of their own too, as bv does:
    /// `--label` scopes the issue set, and `--alert-label` filters the alerts
    /// computed over it, `--capacity-label` the beads simulated.
    case scoped
    /// bv resolves the recipe and loads issues, but the output reads neither:
    /// a recipe that does not resolve fails the command, and otherwise the
    /// flags change nothing.
    case validated
    /// bv scopes the command and vbx does not yet (vbx-9gl). Either flag is
    /// refused rather than answered over every bead, which would look like a
    /// scoped answer and not be one.
    case unported
}

/// One robot command: the flag, the engine method it calls, and how its
/// companion flags become a request.
struct RobotCommand {
    let flag: String
    let method: String
    let summary: String
    /// Builds the engine request from the parsed options. Returning nil means
    /// no request payload.
    let request: (Options) throws -> [String: Any]?
    /// True when the command needs the expensive metrics before it can answer.
    var waitsForPhase2 = false
    /// What `--label` and `--recipe` do here. Set in the table rather than in
    /// each `request`, so a scope-aware command cannot forget to forward
    /// either.
    var scope = ScopeRule.ignored
    /// True when the command prints the engine's `message` — bv's own text
    /// for the same flag — rather than the payload. The feedback commands are
    /// the only ones: bv prints prose for them whatever `--format` says, and
    /// its errors are plain lines on stderr.
    var printsMessage = false
    /// True when the engine's error is bv's own stderr line for the same
    /// failure, so it is printed bare rather than wrapped — an unknown
    /// `--robot-blocker-chain` bead, which a scope can also leave out.
    var bvErrorText = false
    /// True when bv answers the flag outside robot mode *after loading
    /// issues*, so the loader's warnings reach stderr first — see
    /// ``printLoadWarnings(_:environment:)``. Every robot command is false: bv
    /// keeps stderr clean in robot mode. So are feedback-show and
    /// feedback-reset, which bv answers without loading.
    var printsLoadWarnings = false
    /// True when bv answers the flag before it discovers a workspace or reads
    /// `--workspace`: the four feedback commands. They read the folder as one
    /// repository and its own `.beads/feedback.json`, even where every other
    /// command answers over the workspace above it (vbx-v1t).
    var answersBeforeDiscovery = false

    init(
        _ flag: String, method: String, summary: String, waitsForPhase2: Bool = false,
        scope: ScopeRule = .ignored, printsMessage: Bool = false, bvErrorText: Bool = false,
        printsLoadWarnings: Bool = false, answersBeforeDiscovery: Bool = false,
        request: @escaping (Options) throws -> [String: Any]? = { _ in nil }
    ) {
        self.flag = flag
        self.method = method
        self.summary = summary
        self.request = request
        self.waitsForPhase2 = waitsForPhase2
        self.scope = scope
        self.printsMessage = printsMessage
        self.bvErrorText = bvErrorText
        self.printsLoadWarnings = printsLoadWarnings
        self.answersBeforeDiscovery = answersBeforeDiscovery
    }

    /// True when a `--recipe` must resolve before the command runs: bv
    /// resolves it before loading issues, so it fails every command that
    /// loads them.
    var resolvesRecipe: Bool { scope == .scoped || scope == .validated }

    /// The engine request: the command's own, plus the scope.
    func payload(_ options: Options) throws -> [String: Any]? {
        var payload = try request(options)
        guard scope == .scoped else { return payload }
        var scope: [String: Any] = [:]
        if let label = options.label, !label.isEmpty { scope["label"] = label }
        if let recipe = options.recipe, !recipe.isEmpty { scope["recipe"] = recipe }
        if !scope.isEmpty {
            payload = (payload ?? [:]).merging(scope) { _, scope in scope }
        }
        return payload
    }
}

/// Raised when the arguments are wrong, which is exit code 2 rather than 1.
struct UsageError: Error {
    let message: String
}

func requireID(_ options: Options, for flag: String) throws -> String {
    guard let id = options.id, !id.isEmpty else {
        throw UsageError(message: "--\(flag) requires --id")
    }
    return id
}

/// The commands bv lets `--robot-not-ready-labels` modify. Any other is a
/// usage error, as it is in bv.
let notReadyCommands: Set<String> = ["robot-triage", "robot-next"]

/// bv's opt-in not-ready label-class for triage and --robot-next: the flag when
/// it is set, else `BV_ROBOT_NOT_READY_LABELS`. Passed as written — the engine
/// splits and trims it, as bv's `resolveNotReadyLabels` does.
func notReadyRequest(_ options: Options) -> [String: Any]? {
    options.notReadyLabels.map { ["not_ready_labels": $0] }
}

/// Resolves the flag against the environment variable bv falls back to.
func resolvedNotReadyLabels(flag: String?, environment: [String: String]) -> String? {
    if let flag, !flag.trimmingCharacters(in: .whitespaces).isEmpty { return flag }
    if let value = environment["BV_ROBOT_NOT_READY_LABELS"],
        !value.trimmingCharacters(in: .whitespaces).isEmpty
    {
        return value
    }
    return nil
}

let robotCommands: [RobotCommand] = [
    // Triage and planning
    RobotCommand(
        "robot-triage", method: "triage", summary: "Ranked recommendations",
        waitsForPhase2: true, scope: .scoped, request: notReadyRequest),
    RobotCommand(
        "robot-next", method: "next", summary: "The single claim-safe next bead",
        waitsForPhase2: true, scope: .scoped, request: notReadyRequest),
    RobotCommand(
        "robot-plan", method: "plan", summary: "Parallel execution tracks",
        scope: .scoped),
    RobotCommand(
        "robot-priority", method: "priority", summary: "Priority misalignment",
        waitsForPhase2: true, scope: .scoped,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.minConfidence { request["min_confidence"] = value }
            if let value = options.maxResults { request["max_results"] = value }
            if let value = options.byLabel { request["by_label"] = value }
            if let value = options.byAssignee { request["by_assignee"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-insights", method: "insights", summary: "Deep graph metrics",
        waitsForPhase2: true, scope: .scoped,
        request: { options in options.limit.map { ["limit": $0] } }),
    RobotCommand(
        "robot-actionable", method: "actionable", summary: "Beads with nothing blocking them"),
    RobotCommand(
        "robot-metrics", method: "metrics", summary: "Graph metrics"),
    RobotCommand(
        "robot-impact-scores", method: "impact", summary: "Composite impact scores",
        waitsForPhase2: true),

    // Hygiene and health
    RobotCommand(
        "robot-suggest", method: "suggest", summary: "Duplicates, deps, labels, cycles",
        scope: .scoped,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.suggestType { request["type"] = value }
            if let value = options.minConfidence { request["min_confidence"] = value }
            if let value = options.id { request["bead"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-alerts", method: "alerts", summary: "Drift and health alerts",
        scope: .scoped,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.severity { request["severity"] = value }
            if let value = options.alertType { request["type"] = value }
            if let value = options.alertLabel { request["alert_label"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-drift", method: "drift", summary: "Drift against the saved baseline",
        scope: .unported),
    RobotCommand("robot-baseline", method: "baseline_info", summary: "The saved baseline"),

    // Labels
    RobotCommand(
        "robot-label-health", method: "label_health", summary: "Per-label health",
        scope: .scoped),
    RobotCommand(
        "robot-label-flow", method: "label_flow", summary: "Cross-label flow", scope: .scoped),
    RobotCommand(
        "robot-label-attention", method: "label_attention", summary: "Attention ranking",
        scope: .scoped),

    // Graph
    RobotCommand(
        "robot-graph", method: "graph_export", summary: "Graph export",
        scope: .scoped,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.graphFormat { request["format"] = value }
            if let value = options.root { request["root"] = value }
            if let value = options.depth { request["depth"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-blocker-chain", method: "blocker_chain", summary: "Full blocker chain",
        scope: .scoped, bvErrorText: true,
        request: { options in ["id": try requireID(options, for: "robot-blocker-chain")] }),
    RobotCommand(
        "robot-unblocks", method: "unblocks", summary: "What closing a bead unblocks",
        request: { options in ["id": try requireID(options, for: "robot-unblocks")] }),

    // Search
    RobotCommand(
        "robot-search", method: "search", summary: "Search (text or hybrid)",
        scope: .scoped,
        request: { options in
            guard let query = options.query, !query.isEmpty else {
                throw UsageError(message: "--robot-search requires --search")
            }
            var request: [String: Any] = ["query": query]
            if let value = options.searchMode { request["mode"] = value }
            if let value = options.searchPreset { request["preset"] = value }
            if let value = options.limit { request["limit"] = value }
            if let value = options.searchMinScore { request["min_score"] = value }
            return request
        }),
    RobotCommand(
        "robot-search-presets", method: "search_presets", summary: "Available weight presets"),

    // History and correlation. bv builds each report from its scoped issues;
    // vbx's is the whole workspace's, so the scope is refused (vbx-9gl).
    RobotCommand(
        "robot-history", method: "history", summary: "Bead-to-commit correlation",
        scope: .unported,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.id { request["id"] = value }
            if let value = options.limit { request["limit"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-causality", method: "causality", summary: "One bead's causal chain",
        scope: .unported,
        request: { options in ["id": try requireID(options, for: "robot-causality")] }),
    RobotCommand(
        "robot-related", method: "related", summary: "Related work",
        scope: .unported,
        request: { options in ["id": try requireID(options, for: "robot-related")] }),
    RobotCommand(
        "robot-impact-network", method: "impact_network", summary: "Bead impact network",
        scope: .unported,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.id { request["id"] = value }
            if let value = options.depth { request["depth"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-orphans", method: "orphans", summary: "Commits no bead accounts for",
        scope: .unported,
        request: { options in options.limit.map { ["limit": $0] } }),
    RobotCommand(
        "robot-file-beads", method: "file_beads", summary: "Beads that touched a file",
        scope: .unported,
        request: { options in
            guard let path = options.file else {
                throw UsageError(message: "--robot-file-beads requires --file")
            }
            return ["path": path]
        }),
    RobotCommand(
        "robot-file-hotspots", method: "file_hotspots", summary: "Most-touched files",
        scope: .unported,
        request: { options in options.limit.map { ["limit": $0] } }),
    RobotCommand(
        "robot-file-relations", method: "file_relations", summary: "Co-change partners",
        scope: .unported,
        request: { options in
            guard let path = options.file else {
                throw UsageError(message: "--robot-file-relations requires --file")
            }
            var request: [String: Any] = ["path": path]
            if let value = options.threshold { request["threshold"] = value }
            if let value = options.limit { request["limit"] = value }
            return request
        }),
    RobotCommand(
        "robot-impact", method: "file_impact", summary: "Risk of changing files",
        scope: .unported,
        request: { options in
            guard let files = options.files, !files.isEmpty else {
                throw UsageError(message: "--robot-impact requires --files")
            }
            return ["files": files]
        }),
    // bv loads and scopes issues first, then reports the feedback file alone.
    RobotCommand(
        "robot-correlation-stats", method: "correlation_feedback",
        summary: "Correlation feedback accuracy", scope: .validated),

    // Time travel
    RobotCommand("robot-revisions", method: "revisions", summary: "Bead-changing commits"),
    RobotCommand(
        "robot-snapshot", method: "snapshot_at", summary: "Beads as of a revision",
        request: { options in options.revision.map { ["revision": $0] } }),
    RobotCommand(
        "robot-diff", method: "diff", summary: "Diff against a revision",
        scope: .unported,
        request: { options in
            guard let revision = options.revision else {
                throw UsageError(message: "--robot-diff requires --diff-since")
            }
            return ["revision": revision]
        }),

    // Sprints
    RobotCommand(
        "robot-sprint-list", method: "sprint_list", summary: "All sprints", scope: .scoped),
    RobotCommand(
        "robot-sprint-show", method: "sprint_show", summary: "One sprint",
        scope: .scoped,
        request: { options in ["id": options.id ?? "current"] }),
    RobotCommand(
        "robot-burndown", method: "burndown", summary: "Sprint burndown",
        scope: .scoped,
        request: { options in ["id": options.id ?? "current"] }),
    RobotCommand(
        "robot-capacity", method: "capacity", summary: "Capacity simulation",
        scope: .scoped,
        request: { options in
            var request: [String: Any] = ["agents": options.agents]
            if let value = options.capacityLabel { request["capacity_label"] = value }
            return request
        }),
    RobotCommand(
        "robot-forecast", method: "eta", summary: "ETA for one bead",
        scope: .unported,
        request: { options in
            [
                "id": try requireID(options, for: "robot-forecast"),
                "agents": options.agents,
            ]
        }),

    // Recipes and workspace
    RobotCommand("robot-recipes", method: "recipes", summary: "Available recipes"),
    RobotCommand(
        "robot-recipe-apply", method: "recipe_apply", summary: "Beads a recipe selects",
        request: { options in
            guard let name = options.recipe else {
                throw UsageError(message: "--robot-recipe-apply requires --recipe")
            }
            return ["name": name]
        }),
    RobotCommand("robot-repos", method: "repos", summary: "Repositories in the workspace"),
    RobotCommand("robot-info", method: "info", summary: "Resolved source and hash"),
    RobotCommand("robot-issues", method: "issues", summary: "Every bead"),

    // Triage feedback: .beads/feedback.json, which triage, next and priority
    // apply once it holds three verdicts. The accept and ignore flags take the
    // bead id as their value, as bv's do. These write inside the folder's own
    // .beads: bv answers them before workspace discovery and --workspace.
    RobotCommand(
        "feedback-accept", method: "triage_feedback_record",
        summary: "Record that a recommendation was taken", printsMessage: true,
        printsLoadWarnings: true, answersBeforeDiscovery: true,
        request: { options in ["id": options.id ?? "", "action": "accept"] }),
    RobotCommand(
        "feedback-ignore", method: "triage_feedback_record",
        summary: "Record that a recommendation was passed over", printsMessage: true,
        printsLoadWarnings: true, answersBeforeDiscovery: true,
        request: { options in ["id": options.id ?? "", "action": "ignore"] }),
    RobotCommand(
        "feedback-reset", method: "triage_feedback_reset",
        summary: "Clear every verdict and weight adjustment", printsMessage: true,
        answersBeforeDiscovery: true),
    RobotCommand(
        "feedback-show", method: "triage_feedback",
        summary: "The verdicts and adjusted weights", printsMessage: true,
        answersBeforeDiscovery: true),
]

// MARK: - Report export

/// bv's report flags. `--export` and `--export-md` are not robot commands —
/// they write a file and print progress, as bv's do — so they are a mode of
/// their own rather than an entry in `robotCommands`.
let exportFlags = ["export", "export-md"]

/// The flags that only mean something beside `--export` or `--export-md`.
/// bv rejects each on its own, and so does vbx-cli.
let exportModifiers = ["export-format", "export-include-graph", "export-template"]

/// bv's `parseSearchMinScore`: an empty value is no threshold; anything else
/// must be a finite number from -1 to 1, or the invocation is wrong (exit 2)
/// with bv's message word for word.
func parseSearchMinScore(_ raw: String) throws -> Double? {
    if raw.isEmpty { return nil }
    guard let score = Double(raw), score.isFinite, score >= -1, score <= 1 else {
        throw UsageError(
            message: "invalid --search-min-score \"\(raw)\" (expected a finite number from -1 to 1)")
    }
    return score
}

/// Parses a Go `strconv.ParseBool` value, which is what pflag accepts for
/// `--export-include-graph=<value>`.
func parseGoBool(_ value: String) -> Bool? {
    switch value {
    case "1", "t", "T", "TRUE", "true", "True": true
    case "0", "f", "F", "FALSE", "false", "False": false
    default: nil
    }
}

/// The engine request for an export. Only the modifiers that were given are
/// sent, so a recipe's `export:` defaults apply to the rest — bv's
/// `ReportOverrides`. `--export-md` forces Markdown whatever `--export-format`
/// says, as it does in bv.
func exportRequest(_ options: Options, path: String) -> [String: Any] {
    var request: [String: Any] = ["path": path]
    if let value = options.exportFormat { request["format"] = value }
    if let value = options.exportIncludeGraph { request["include_graph"] = value }
    if let value = options.exportTemplate { request["template"] = value }
    if options.exportMarkdownPath != nil { request["format"] = "markdown" }
    if let value = options.recipe { request["recipe"] = value }
    if let value = options.label, !value.isEmpty { request["label"] = value }
    return request
}

/// Runs `--export` / `--export-md`: renders the report, writes it, and prints
/// bv's two progress lines. Failures print the engine's message bare on
/// stderr, which is bv's own text for the same failure.
func runExport(_ options: Options, path: String, engine: BeadsEngine) async -> Int32 {
    struct Reply: Decodable {
        let issueCount: Int
        let labelMatches: Int?
        let hookOutput: String?
        let hookFailed: Bool?
        private enum CodingKeys: String, CodingKey {
            case issueCount = "issue_count"
            case labelMatches = "label_matches"
            case hookOutput = "hook_output"
            case hookFailed = "hook_failed"
        }
    }
    do {
        let data = try await engine.rawJSON(
            "export_report", request: exportRequest(options, path: path))
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if reply.labelMatches == 0, let label = options.label {
            // bv's warning, word for word: an unknown label exports an empty
            // report rather than failing.
            complain("Warning: No issues found with label \"\(label)\"")
        }
        emit("Exporting \(reply.issueCount) issues to \(path)...")
        // bv's hook lines, the summary and any failure, already formatted by
        // bv's own code in the engine. All of it is stdout, as in bv, and a
        // failed hook is bv's exit 1 with no "Done!".
        // Through print, as emit is: a direct write would bypass print's
        // buffer and land before the "Exporting" line on a pipe.
        if let output = reply.hookOutput, !output.isEmpty {
            print(output, terminator: "")
        }
        if reply.hookFailed == true { return 1 }
        emit("Done!")
        return 0
    } catch EngineError.callFailed(_, let message) {
        complain(message)
        return 1
    } catch {
        complain("Error exporting: \(error.localizedDescription)")
        return 1
    }
}

// MARK: - Options

struct Options {
    var command: String?
    var path = FileManager.default.currentDirectoryPath
    /// bv's --workspace: a workspace configuration loaded as given, with no
    /// discovery. Without it the path is discovered by bv's precedence, where
    /// a reachable `.beads` wins over a `.bv/workspace.yaml` (ADR-026).
    var workspace: String?
    var format = "json"
    var id: String?
    var file: String?
    var files: [String]?
    var label: String?
    var root: String?
    var recipe: String?
    var revision: String?
    var query: String?
    var searchMode: String?
    var searchPreset: String?
    /// bv's --search-min-score, as given; parsed once the query is known.
    var searchMinScoreText: String?
    var searchMinScore: Double?
    var suggestType: String?
    var severity: String?
    var alertType: String?
    var alertLabel: String?
    var capacityLabel: String?
    var graphFormat: String?
    var agents = 1
    var depth: Int?
    var limit: Int?
    var maxResults: Int?
    var minConfidence: Double?
    var threshold: Double?
    var byLabel: String?
    var byAssignee: String?
    var notReadyLabels: String?
    var exportPath: String?
    var exportMarkdownPath: String?
    var exportFormat: String?
    var exportIncludeGraph: Bool?
    var exportTemplate: String?
    /// bv's --no-hooks: skip `.bv/hooks.yaml` around an export. Accepted, and
    /// meaningless, without one, as in bv.
    var noHooks = false
    /// Every flag given, by name, so a modifier can be checked against the
    /// command it needs whether or not it carried a value.
    var given: Set<String> = []
    var pretty = false
    var listCommands = false
    var showHelp = false
}

func parseArguments() throws -> Options {
    var options = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0

    func next(_ flag: String) throws -> String {
        index += 1
        guard index < args.count else {
            throw UsageError(message: "\(flag) requires a value")
        }
        return args[index]
    }

    /// Makes `arg` the invocation's command.
    func select(_ arg: String) throws {
        let name = String(arg.dropFirst(2))
        guard robotCommands.contains(where: { $0.flag == name }) else {
            throw UsageError(message: "unknown command \(arg)")
        }
        if let existing = options.command, existing != name {
            // Two primary commands in one invocation is ambiguous, and
            // silently picking one would produce the wrong payload — or, for
            // a feedback command, write the wrong verdict.
            throw UsageError(message: "--\(existing) and \(arg) cannot be used together")
        }
        options.command = name
    }

    while index < args.count {
        var arg = args[index]
        // pflag's `--flag=value` spelling, for the report flags: bv's
        // `--export-include-graph` is a boolean that takes its value only that
        // way, and `--export-template=` is how an empty template is written.
        var inline: String?
        if arg.hasPrefix("--export"), let equals = arg.firstIndex(of: "=") {
            inline = String(arg[arg.index(after: equals)...])
            arg = String(arg[..<equals])
        }
        func value(_ flag: String) throws -> String {
            if let inline { return inline }
            return try next(flag)
        }
        if arg.hasPrefix("--") { options.given.insert(String(arg.dropFirst(2))) }
        switch arg {
        case "--export": options.exportPath = try value(arg)
        case "--export-md": options.exportMarkdownPath = try value(arg)
        case "--export-format": options.exportFormat = try value(arg)
        case "--export-template": options.exportTemplate = try value(arg)
        case "--export-include-graph":
            if let inline {
                guard let parsed = parseGoBool(inline) else {
                    throw UsageError(
                        message: "invalid argument \"\(inline)\" for --export-include-graph")
                }
                options.exportIncludeGraph = parsed
            } else {
                options.exportIncludeGraph = true
            }
        case "--no-hooks": options.noHooks = true
        case "--path": options.path = try next(arg)
        case "--workspace": options.workspace = try next(arg)
        case "--format", "-f": options.format = try next(arg).lowercased()
        case "--json": options.format = "json"
        case "--toon": options.format = "toon"
        case "--id": options.id = try next(arg)
        case "--file": options.file = try next(arg)
        case "--files":
            options.files = try next(arg).split(separator: ",").map(String.init)
        case "--label": options.label = try next(arg)
        case "--root": options.root = try next(arg)
        case "--recipe": options.recipe = try next(arg)
        case "--diff-since", "--as-of", "--revision": options.revision = try next(arg)
        case "--search": options.query = try next(arg)
        case "--search-mode": options.searchMode = try next(arg)
        case "--search-preset": options.searchPreset = try next(arg)
        case "--search-min-score": options.searchMinScoreText = try next(arg)
        case "--suggest-type": options.suggestType = try next(arg)
        case "--severity": options.severity = try next(arg)
        case "--alert-type": options.alertType = try next(arg)
        case "--alert-label": options.alertLabel = try next(arg)
        case "--capacity-label": options.capacityLabel = try next(arg)
        case "--graph-format": options.graphFormat = try next(arg)
        case "--agents": options.agents = Int(try next(arg)) ?? 1
        case "--depth": options.depth = Int(try next(arg))
        case "--limit": options.limit = Int(try next(arg))
        case "--max-results": options.maxResults = Int(try next(arg))
        case "--min-confidence": options.minConfidence = Double(try next(arg))
        case "--threshold": options.threshold = Double(try next(arg))
        case "--by-label": options.byLabel = try next(arg)
        case "--by-assignee": options.byAssignee = try next(arg)
        // A modifier spelled like a command, so it is matched before the
        // `--robot-` prefix below would take it for one.
        case "--robot-not-ready-labels": options.notReadyLabels = try next(arg)
        case "--pretty": options.pretty = true
        case "--list-commands": options.listCommands = true
        case "--help", "-h": options.showHelp = true
        case "--feedback-accept", "--feedback-ignore":
            try select(arg)
            // bv's spelling: the id is the flag's value, not --id.
            let value = try next(arg)
            guard !value.isEmpty, !value.hasPrefix("-") else {
                throw UsageError(message: "\(arg) requires a bead id")
            }
            options.id = value
        case "--feedback-reset", "--feedback-show":
            try select(arg)
        default:
            if arg.hasPrefix("--robot-") || arg == "--bead-history" {
                try select(arg)
            } else if arg.hasPrefix("-") {
                throw UsageError(message: "unknown flag \(arg)")
            } else {
                throw UsageError(message: "unexpected argument \(arg)")
            }
        }
        index += 1
    }

    if options.given.contains("workspace"), options.given.contains("path") {
        // --workspace names what to load and --path where to discover it
        // from; together one of them would be silently ignored.
        throw UsageError(message: "--workspace and --path cannot be used together")
    }
    for modifier in exportModifiers where options.given.contains(modifier) {
        if options.exportPath == nil, options.exportMarkdownPath == nil {
            throw UsageError(message: "--\(modifier) requires one of --export or --export-md")
        }
    }
    if options.exportPath != nil || options.exportMarkdownPath != nil {
        if options.exportPath != nil, options.exportMarkdownPath != nil {
            throw UsageError(message: "--export and --export-md specify conflicting output paths")
        }
        if let command = options.command {
            throw UsageError(message: "--\(command) cannot be combined with an export")
        }
        if options.revision != nil {
            // bv exports a historical snapshot under --as-of; vbx-cli does
            // not, and silently exporting the present would be wrong.
            throw UsageError(message: "--as-of is not supported with an export")
        }
    }
    // Checked only beside a query, as bv checks it: without --search the flag
    // means nothing, and bv ignores it rather than failing.
    if let raw = options.searchMinScoreText, options.query?.isEmpty == false {
        options.searchMinScore = try parseSearchMinScore(raw)
    }
    guard ["json", "toon"].contains(options.format) else {
        throw UsageError(message: "invalid --format \(options.format) (expected json or toon)")
    }
    if let name = options.command,
        robotCommands.first(where: { $0.flag == name })?.scope == .unported
    {
        // bv would answer over the scope; answering over every bead instead
        // would look like a scoped answer and not be one.
        for (flag, value) in [("label", options.label), ("recipe", options.recipe)] {
            if let value, !value.isEmpty {
                throw UsageError(
                    message: "--\(flag) does not scope --\(name) in vbx-cli yet (vbx-9gl)")
            }
        }
    }
    if options.notReadyLabels != nil, let command = options.command,
        !notReadyCommands.contains(command)
    {
        throw UsageError(
            message: "--robot-not-ready-labels requires one of --robot-triage or --robot-next")
    }
    // The environment applies only where the flag would, so an exported
    // variable never makes another command a usage error.
    if let command = options.command, notReadyCommands.contains(command) {
        options.notReadyLabels = resolvedNotReadyLabels(
            flag: options.notReadyLabels, environment: ProcessInfo.processInfo.environment)
    }
    return options
}

// MARK: - Output

let standardError = FileHandle.standardError

/// Diagnostics go to stderr, so stdout stays parseable.
func complain(_ message: String) {
    standardError.write(Data((message + "\n").utf8))
}

func emit(_ text: String) {
    print(text)
}

func prettyPrinted(_ data: Data) -> String {
    guard
        let object = try? JSONSerialization.jsonObject(with: data),
        let encoded = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return String(decoding: data, as: UTF8.self) }
    return String(decoding: encoded, as: UTF8.self)
}

/// The commands a scope rule covers, by name without the `robot-` prefix.
func scopeNames(_ rule: ScopeRule) -> String {
    robotCommands.filter { $0.scope == rule }
        .map { $0.flag.hasPrefix("robot-") ? String($0.flag.dropFirst(6)) : $0.flag }
        .joined(separator: ", ")
}

/// Wraps text at word boundaries into lines of at most `width` characters,
/// each starting with `indent`.
func wrapped(_ text: String, indent: String, width: Int = 79) -> [String] {
    var lines: [String] = []
    var line = indent
    for word in text.split(separator: " ") {
        if line.count > indent.count, line.count + 1 + word.count > width {
            lines.append(line)
            line = indent
        }
        line += (line.count > indent.count ? " " : "") + word
    }
    if line.count > indent.count { lines.append(line) }
    return lines
}

func usageText() -> String {
    var lines = [
        "vbx-cli — bv's robot protocol, over the vbx engine",
        "",
        "USAGE:",
        "  vbx-cli --robot-<command> [--path PATH] [--format json|toon] [options]",
        "",
        "COMMANDS:",
    ]
    for command in robotCommands.sorted(by: { $0.flag < $1.flag }) {
        lines.append("  --\(command.flag.padding(toLength: 26, withPad: " ", startingAt: 0))"
            + command.summary)
    }
    lines.append(contentsOf: [
        "",
        "COMMON OPTIONS:",
        "  --path PATH          Folder, .beads directory, data file or workspace.yaml",
        "  --workspace FILE     Load this .bv/workspace.yaml, skipping discovery",
        "  --format json|toon   Output format (default json)",
        "  --pretty             Indent JSON output",
        "  --list-commands      Print the command list as JSON",
        "",
        "SCOPE:",
        "  --label L            The label's subgraph; only its beads are picked",
        "  --recipe NAME|FILE   What a recipe selects — a name, or a .yaml/.yml path",
    ])
    // Listed from the table, so the help cannot name a command the table
    // does not scope.
    lines.append(contentsOf: wrapped(
        "Scoped: " + scopeNames(.scoped), indent: "                       "))
    lines.append(contentsOf: wrapped(
        "Refused, not yet scoped (vbx-9gl): " + scopeNames(.unported),
        indent: "                       "))
    lines.append(contentsOf: [
        "",
        "REPORTS (bv's --export):",
        "  --export FILE        Write a report; a --recipe supplies export defaults",
        "  --export-md FILE     The same, always Markdown",
        "  --export-format markdown|json|csv|mermaid",
        "  --export-include-graph[=false]",
        "                       Include the dependency context (default: all but csv)",
        "  --export-template FILE",
        "                       A Go text/template for the Markdown report;",
        "                       --export-template= disables a recipe's",
        "  --no-hooks           Skip .bv/hooks.yaml; by default its pre- and",
        "                       post-export commands run around the write, as",
        "                       bv runs them (they are the repository's commands)",
        "",
        "SEARCH (--robot-search):",
        "  --search QUERY       The query; a bead id returns that bead first",
        "  --search-mode text|hybrid / --search-preset NAME / --limit N",
        "  --search-min-score S Minimum text similarity before hybrid ranking",
        "                       (-1..1); exact ids also obey it",
        "",
        "TRIAGE AND --robot-next:",
        "  --robot-not-ready-labels A,B",
        "                       Labels whose beads are never a claimable top pick",
        "                       (env: BV_ROBOT_NOT_READY_LABELS)",
        "",
        "TRIAGE FEEDBACK (writes .beads/feedback.json, as bv does):",
        "  --feedback-accept ID / --feedback-ignore ID",
        "                       Record a verdict on a recommendation; the weights",
        "                       apply to triage once three verdicts exist",
        "  --feedback-show      The verdicts and adjusted weights",
        "  --feedback-reset     Clear them",
        "",
        "EXIT CODES:",
        "  0  Success",
        "  1  Error",
        "  2  Invalid arguments",
    ])
    return lines.joined(separator: "\n")
}

/// Runs a command that prints bv's text: the engine's `message` on stdout, or
/// the engine's error — itself bv's stderr line — on stderr, exit 1.
func printMessage(
    of command: RobotCommand, request: [String: Any]?, engine: BeadsEngine
) async -> Int32 {
    struct Reply: Decodable { let message: String }
    do {
        let data = try await engine.rawJSON(command.method, request: request)
        emit(try JSONDecoder().decode(Reply.self, from: data).message)
        return 0
    } catch EngineError.callFailed(_, let message) {
        complain(message)
        return 1
    } catch {
        complain("Error handling --\(command.flag): \(error.localizedDescription)")
        return 1
    }
}

/// bv's `env.Robot.Bool()`: `BV_ROBOT` set to 1, true, yes or on, in any case
/// and with surrounding space, forces robot mode on every command.
func robotModeForced(_ environment: [String: String]) -> Bool {
    let value = (environment["BV_ROBOT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return ["1", "true", "yes", "on"].contains(value)
}

/// Prints the loader's warnings as bv does when it loads issues outside robot
/// mode: each line on stderr, before anything the command prints itself
/// (vbx-1l6). The lines are the engine's — bv's text for the same load — so
/// all this decides is *whether*: the one place vbx-cli prints them, for every
/// command bv answers that way. Those are `--export`, `--export-md` and each
/// command whose ``RobotCommand/printsLoadWarnings`` is set. Call it after
/// `--recipe` resolves, because bv resolves it before loading: a recipe that
/// fails stops bv before there is anything to warn about.
func printLoadWarnings(
    _ info: WorkspaceInfo,
    environment: [String: String] = ProcessInfo.processInfo.environment
) {
    guard !robotModeForced(environment) else { return }
    for line in info.loadStderr { complain(line) }
}

/// Resolves `--recipe` before anything runs, as bv does, and refuses one that
/// names no recipe or no loadable file with bv's stderr: the error, the
/// loader's warnings, and — for an unknown name — the recipes it could have
/// named. Returns false when the run must stop (exit 1).
func recipeResolves(_ argument: String, engine: BeadsEngine) async -> Bool {
    struct Summary: Decodable {
        let name: String
        let description: String?
    }
    struct Resolution: Decodable {
        let error: String?
        let warnings: [String]?
        let available: [Summary]?
    }
    do {
        let data = try await engine.rawJSON("recipe_resolve", request: ["name": argument])
        let resolution = try JSONDecoder().decode(Resolution.self, from: data)
        guard let error = resolution.error else { return true }
        complain("Error: \(error)")
        for warning in resolution.warnings ?? [] { complain("Warning: \(warning)") }
        if let available = resolution.available {
            complain("\nAvailable recipes:")
            for recipe in available {
                let name = recipe.name.padding(
                    toLength: max(15, recipe.name.count), withPad: " ", startingAt: 0)
                complain("  \(name) \(recipe.description ?? "")")
            }
            complain(
                "\nA path ending in .yaml or .yml loads one recipe file, e.g. --recipe .beads/recipes/sprint.yaml"
            )
        }
        return false
    } catch {
        complain("Error: \(error.localizedDescription)")
        return false
    }
}

// MARK: - Main

func run() async -> Int32 {
    let options: Options
    do {
        options = try parseArguments()
    } catch let error as UsageError {
        complain("Error: \(error.message)")
        complain("Run vbx-cli --help for the command list.")
        return 2
    } catch {
        complain("Error: \(error)")
        return 2
    }

    if options.showHelp {
        emit(usageText())
        return 0
    }

    if options.listCommands {
        // Machine-readable, so a parity harness can enumerate coverage rather
        // than hardcoding a list that silently goes stale.
        let entries = robotCommands.map {
            ["flag": $0.flag, "method": $0.method, "summary": $0.summary]
        }
        let payload: [String: Any] = [
            "commands": entries, "formats": ["json", "toon"], "exports": exportFlags,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return 1 }
        emit(String(decoding: data, as: UTF8.self))
        return 0
    }

    if let path = options.exportPath ?? options.exportMarkdownPath {
        let engine = BeadsEngine()
        let info: WorkspaceInfo
        do {
            // Live tracker actions, as for the robot commands: a report's
            // per-bead claim commands come from the same binding (ADR-020).
            // Export hooks are repository-configured commands, run as bv runs
            // them; the CLI is never sandboxed, and the app never asks.
            info = try await engine.open(
                path: options.path, liveTrackerActions: true, exportHooks: !options.noHooks,
                workspace: options.workspace)
        } catch {
            complain("Error: \(error.localizedDescription)")
            return 1
        }
        defer { Task { await engine.close() } }
        if let recipe = options.recipe, !(await recipeResolves(recipe, engine: engine)) {
            return 1
        }
        printLoadWarnings(info)
        return await runExport(options, path: path, engine: engine)
    }

    guard let name = options.command,
        let command = robotCommands.first(where: { $0.flag == name })
    else {
        complain("Error: no command given.")
        complain(usageText())
        return 2
    }

    let request: [String: Any]?
    do {
        request = try command.payload(options)
    } catch let error as UsageError {
        complain("Error: \(error.message)")
        return 2
    } catch {
        complain("Error: \(error)")
        return 2
    }

    let engine = BeadsEngine()
    let info: WorkspaceInfo
    do {
        // The CLI is never sandboxed, so it alone may ask `br` what it
        // supports — which is what puts claim commands in triage and
        // --robot-next (ADR-020). The app leaves this off.
        info = try await engine.open(
            path: options.path, liveTrackerActions: true, workspace: options.workspace,
            feedbackCommand: command.answersBeforeDiscovery)
    } catch {
        complain("Error: \(error.localizedDescription)")
        return 1
    }
    defer { Task { await engine.close() } }

    // bv resolves --recipe before it loads issues, so a recipe that does not
    // resolve fails the command whatever it is; here, every command that
    // reads the recipe.
    if command.resolvesRecipe || command.flag == "robot-recipe-apply", let recipe = options.recipe,
        !(await recipeResolves(recipe, engine: engine))
    {
        return 1
    }

    if command.printsLoadWarnings {
        printLoadWarnings(info)
    }

    if command.waitsForPhase2 {
        // Metrics that have not been computed would be reported as absent,
        // which is correct but useless for a command whose whole answer is a
        // ranking derived from them.
        _ = try? await engine.rawJSON("wait_phase2")
    }

    if command.printsMessage {
        return await printMessage(of: command, request: request, engine: engine)
    }

    do {
        let data = try await engine.rawJSON(command.method, request: request)

        if options.format == "toon" {
            let object = RobotEnvelope.stamping(
                format: "toon", on: try JSONSerialization.jsonObject(with: data))
            let wrapped = try await engine.rawJSON("toon", request: ["value": object])
            struct Wrapper: Decodable { let toon: String }
            let decoded = try JSONDecoder().decode(Wrapper.self, from: wrapped)
            emit(decoded.toon)
            return 0
        }

        emit(options.pretty ? prettyPrinted(data) : String(decoding: data, as: UTF8.self))
        return 0
    } catch EngineError.callFailed(_, let message) where command.bvErrorText {
        complain(message)
        return 1
    } catch {
        complain("Error handling --\(command.flag): \(error.localizedDescription)")
        return 1
    }
}

exit(await run())
