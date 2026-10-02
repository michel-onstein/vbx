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
    /// True when `--label` is bv's global scope for this command: the engine
    /// answers over the label's subgraph and says so in the envelope. Set here
    /// rather than in each `request`, so a label-aware command cannot forget
    /// to forward it. Alerts and capacity take a filter of their own too, as
    /// bv does: `--label` scopes the issue set, and `--alert-label` filters
    /// the alerts computed over it, `--capacity-label` the beads simulated.
    var labelScoped = false
    /// True when the command prints the engine's `message` — bv's own text
    /// for the same flag — rather than the payload. The feedback commands are
    /// the only ones: bv prints prose for them whatever `--format` says, and
    /// its errors are plain lines on stderr.
    var printsMessage = false

    init(
        _ flag: String, method: String, summary: String, waitsForPhase2: Bool = false,
        labelScoped: Bool = false, printsMessage: Bool = false,
        request: @escaping (Options) throws -> [String: Any]? = { _ in nil }
    ) {
        self.flag = flag
        self.method = method
        self.summary = summary
        self.request = request
        self.waitsForPhase2 = waitsForPhase2
        self.labelScoped = labelScoped
        self.printsMessage = printsMessage
    }

    /// The engine request: the command's own, plus the label scope.
    func payload(_ options: Options) throws -> [String: Any]? {
        var payload = try request(options)
        if labelScoped, let label = options.label, !label.isEmpty {
            payload = (payload ?? [:]).merging(["label": label]) { _, scope in scope }
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
        waitsForPhase2: true, labelScoped: true, request: notReadyRequest),
    RobotCommand(
        "robot-next", method: "next", summary: "The single claim-safe next bead",
        waitsForPhase2: true, labelScoped: true, request: notReadyRequest),
    RobotCommand(
        "robot-plan", method: "plan", summary: "Parallel execution tracks",
        labelScoped: true),
    RobotCommand(
        "robot-priority", method: "priority", summary: "Priority misalignment",
        waitsForPhase2: true, labelScoped: true,
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
        waitsForPhase2: true, labelScoped: true,
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
        labelScoped: true,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.suggestType { request["type"] = value }
            if let value = options.minConfidence { request["min_confidence"] = value }
            if let value = options.id { request["bead"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-alerts", method: "alerts", summary: "Drift and health alerts",
        labelScoped: true,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.severity { request["severity"] = value }
            if let value = options.alertType { request["type"] = value }
            if let value = options.alertLabel { request["alert_label"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand("robot-drift", method: "drift", summary: "Drift against the saved baseline"),
    RobotCommand("robot-baseline", method: "baseline_info", summary: "The saved baseline"),

    // Labels
    RobotCommand("robot-label-health", method: "label_health", summary: "Per-label health"),
    RobotCommand("robot-label-flow", method: "label_flow", summary: "Cross-label flow"),
    RobotCommand(
        "robot-label-attention", method: "label_attention", summary: "Attention ranking"),

    // Graph
    RobotCommand(
        "robot-graph", method: "graph_export", summary: "Graph export",
        labelScoped: true,
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.graphFormat { request["format"] = value }
            if let value = options.root { request["root"] = value }
            if let value = options.depth { request["depth"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-blocker-chain", method: "blocker_chain", summary: "Full blocker chain",
        request: { options in ["id": try requireID(options, for: "robot-blocker-chain")] }),
    RobotCommand(
        "robot-unblocks", method: "unblocks", summary: "What closing a bead unblocks",
        request: { options in ["id": try requireID(options, for: "robot-unblocks")] }),

    // Search
    RobotCommand(
        "robot-search", method: "search", summary: "Search (text or hybrid)",
        request: { options in
            guard let query = options.query, !query.isEmpty else {
                throw UsageError(message: "--robot-search requires --search")
            }
            var request: [String: Any] = ["query": query]
            if let value = options.searchMode { request["mode"] = value }
            if let value = options.searchPreset { request["preset"] = value }
            if let value = options.limit { request["limit"] = value }
            return request
        }),
    RobotCommand(
        "robot-search-presets", method: "search_presets", summary: "Available weight presets"),

    // History and correlation
    RobotCommand(
        "robot-history", method: "history", summary: "Bead-to-commit correlation",
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.id { request["id"] = value }
            if let value = options.limit { request["limit"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-causality", method: "causality", summary: "One bead's causal chain",
        request: { options in ["id": try requireID(options, for: "robot-causality")] }),
    RobotCommand(
        "robot-related", method: "related", summary: "Related work",
        request: { options in ["id": try requireID(options, for: "robot-related")] }),
    RobotCommand(
        "robot-impact-network", method: "impact_network", summary: "Bead impact network",
        request: { options in
            var request: [String: Any] = [:]
            if let value = options.id { request["id"] = value }
            if let value = options.depth { request["depth"] = value }
            return request.isEmpty ? nil : request
        }),
    RobotCommand(
        "robot-orphans", method: "orphans", summary: "Commits no bead accounts for",
        request: { options in options.limit.map { ["limit": $0] } }),
    RobotCommand(
        "robot-file-beads", method: "file_beads", summary: "Beads that touched a file",
        request: { options in
            guard let path = options.file else {
                throw UsageError(message: "--robot-file-beads requires --file")
            }
            return ["path": path]
        }),
    RobotCommand(
        "robot-file-hotspots", method: "file_hotspots", summary: "Most-touched files",
        request: { options in options.limit.map { ["limit": $0] } }),
    RobotCommand(
        "robot-file-relations", method: "file_relations", summary: "Co-change partners",
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
        request: { options in
            guard let files = options.files, !files.isEmpty else {
                throw UsageError(message: "--robot-impact requires --files")
            }
            return ["files": files]
        }),
    RobotCommand(
        "robot-correlation-stats", method: "correlation_feedback",
        summary: "Correlation feedback accuracy"),

    // Time travel
    RobotCommand("robot-revisions", method: "revisions", summary: "Bead-changing commits"),
    RobotCommand(
        "robot-snapshot", method: "snapshot_at", summary: "Beads as of a revision",
        request: { options in options.revision.map { ["revision": $0] } }),
    RobotCommand(
        "robot-diff", method: "diff", summary: "Diff against a revision",
        request: { options in
            guard let revision = options.revision else {
                throw UsageError(message: "--robot-diff requires --diff-since")
            }
            return ["revision": revision]
        }),

    // Sprints
    RobotCommand("robot-sprint-list", method: "sprint_list", summary: "All sprints"),
    RobotCommand(
        "robot-sprint-show", method: "sprint_show", summary: "One sprint",
        request: { options in ["id": options.id ?? "current"] }),
    RobotCommand(
        "robot-burndown", method: "burndown", summary: "Sprint burndown",
        request: { options in ["id": options.id ?? "current"] }),
    RobotCommand(
        "robot-capacity", method: "capacity", summary: "Capacity simulation",
        labelScoped: true,
        request: { options in
            var request: [String: Any] = ["agents": options.agents]
            if let value = options.capacityLabel { request["capacity_label"] = value }
            return request
        }),
    RobotCommand(
        "robot-forecast", method: "eta", summary: "ETA for one bead",
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
    // bead id as their value, as bv's do. These write inside the workspace.
    RobotCommand(
        "feedback-accept", method: "triage_feedback_record",
        summary: "Record that a recommendation was taken", printsMessage: true,
        request: { options in ["id": options.id ?? "", "action": "accept"] }),
    RobotCommand(
        "feedback-ignore", method: "triage_feedback_record",
        summary: "Record that a recommendation was passed over", printsMessage: true,
        request: { options in ["id": options.id ?? "", "action": "ignore"] }),
    RobotCommand(
        "feedback-reset", method: "triage_feedback_reset",
        summary: "Clear every verdict and weight adjustment", printsMessage: true),
    RobotCommand(
        "feedback-show", method: "triage_feedback",
        summary: "The verdicts and adjusted weights", printsMessage: true),
]

// MARK: - Report export

/// bv's report flags. `--export` and `--export-md` are not robot commands —
/// they write a file and print progress, as bv's do — so they are a mode of
/// their own rather than an entry in `robotCommands`.
let exportFlags = ["export", "export-md"]

/// The flags that only mean something beside `--export` or `--export-md`.
/// bv rejects each on its own, and so does vbx-cli.
let exportModifiers = ["export-format", "export-include-graph", "export-template"]

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
        private enum CodingKeys: String, CodingKey {
            case issueCount = "issue_count"
            case labelMatches = "label_matches"
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
        case "--path": options.path = try next(arg)
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
    guard ["json", "toon"].contains(options.format) else {
        throw UsageError(message: "invalid --format \(options.format) (expected json or toon)")
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
        "  --path PATH          Workspace, .beads directory, or data file",
        "  --format json|toon   Output format (default json)",
        "  --pretty             Indent JSON output",
        "  --list-commands      Print the command list as JSON",
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
        do {
            // Live tracker actions, as for the robot commands: a report's
            // per-bead claim commands come from the same binding (ADR-020).
            _ = try await engine.open(path: options.path, liveTrackerActions: true)
        } catch {
            complain("Error: \(error.localizedDescription)")
            return 1
        }
        defer { Task { await engine.close() } }
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
    do {
        // The CLI is never sandboxed, so it alone may ask `br` what it
        // supports — which is what puts claim commands in triage and
        // --robot-next (ADR-020). The app leaves this off.
        _ = try await engine.open(path: options.path, liveTrackerActions: true)
    } catch {
        complain("Error: \(error.localizedDescription)")
        return 1
    }
    defer { Task { await engine.close() } }

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
    } catch {
        complain("Error handling --\(command.flag): \(error.localizedDescription)")
        return 1
    }
}

exit(await run())
