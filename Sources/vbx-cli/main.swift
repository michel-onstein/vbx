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

    init(
        _ flag: String, method: String, summary: String, waitsForPhase2: Bool = false,
        labelScoped: Bool = false,
        request: @escaping (Options) throws -> [String: Any]? = { _ in nil }
    ) {
        self.flag = flag
        self.method = method
        self.summary = summary
        self.request = request
        self.waitsForPhase2 = waitsForPhase2
        self.labelScoped = labelScoped
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

let robotCommands: [RobotCommand] = [
    // Triage and planning
    RobotCommand(
        "robot-triage", method: "triage", summary: "Ranked recommendations",
        waitsForPhase2: true, labelScoped: true),
    RobotCommand(
        "robot-next", method: "next", summary: "The single claim-safe next bead",
        waitsForPhase2: true, labelScoped: true),
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
]

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

    while index < args.count {
        let arg = args[index]
        switch arg {
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
        case "--pretty": options.pretty = true
        case "--list-commands": options.listCommands = true
        case "--help", "-h": options.showHelp = true
        default:
            if arg.hasPrefix("--robot-") || arg == "--bead-history" {
                let name = String(arg.dropFirst(2))
                guard robotCommands.contains(where: { $0.flag == name }) else {
                    throw UsageError(message: "unknown command \(arg)")
                }
                if let existing = options.command, existing != name {
                    // Two primary commands in one invocation is ambiguous, and
                    // silently picking one would produce the wrong payload.
                    throw UsageError(
                        message: "--\(existing) and \(arg) cannot be used together")
                }
                options.command = name
            } else if arg.hasPrefix("-") {
                throw UsageError(message: "unknown flag \(arg)")
            } else {
                throw UsageError(message: "unexpected argument \(arg)")
            }
        }
        index += 1
    }

    guard ["json", "toon"].contains(options.format) else {
        throw UsageError(message: "invalid --format \(options.format) (expected json or toon)")
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
        "EXIT CODES:",
        "  0  Success",
        "  1  Error",
        "  2  Invalid arguments",
    ])
    return lines.joined(separator: "\n")
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
        let payload: [String: Any] = ["commands": entries, "formats": ["json", "toon"]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return 1 }
        emit(String(decoding: data, as: UTF8.self))
        return 0
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
