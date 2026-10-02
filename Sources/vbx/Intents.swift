import AppIntents
import VBXAppCore
import VBXCore
import VBXEngine
import Foundation

// Shortcuts actions.
//
// Every intent opens its own engine session rather than reaching into the
// running app's store. That is deliberate: a Shortcut can run while no window
// is open, and an intent that only worked when the app happened to be showing
// the right workspace would be unreliable in exactly the automation setting it
// exists for.
//
// Note on discovery: Shortcuts finds intents through an App Intents metadata
// bundle that Xcode's `appintentsmetadataprocessor` produces. A plain
// `swift build` does not run it, so these compile and work but are only listed
// in Shortcuts when the app is built through Xcode or that step is added to
// `scripts/build-app.sh`.

/// Resolves the workspace an intent should act on.
///
/// The parameter wins; otherwise `VBX_WORKSPACE`, then the working directory —
/// the same order the app itself uses, so an intent and the app agree about
/// what "the workspace" means.
private func resolveWorkspace(_ path: String?) -> String {
    if let path, !path.isEmpty { return path }
    if let env = ProcessInfo.processInfo.environment["VBX_WORKSPACE"] { return env }
    return FileManager.default.currentDirectoryPath
}

/// Opens a session, runs `body`, and always closes it.
private func withSession<T>(
    _ path: String?, _ body: (BeadsEngine) async throws -> T
) async throws -> T {
    let engine = BeadsEngine()
    // The app's id-prefix patterns too, so an intent's triage scores
    // staleness from the same history the app shows (ADR-027).
    _ = try await engine.open(path: resolveWorkspace(path), idPatternsFromPrefix: true)
    defer { Task { await engine.close() } }
    return try await body(engine)
}

struct GetTriage: AppIntent {
    static var title: LocalizedStringResource = "Get Triage"
    static var description = IntentDescription(
        "The top recommendations for what to work on next, with their scores.")

    @Parameter(title: "Workspace")
    var workspace: String?

    @Parameter(title: "Limit", default: 5)
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = try await withSession(workspace) { engine in
            let triage = try await engine.triage()
            let picks = triage.recommendations.prefix(max(limit, 1))
            guard !picks.isEmpty else { return "Nothing is actionable." }
            return picks
                .map { "\($0.id) — \($0.title) (score \(String(format: "%.2f", $0.score)))" }
                .joined(separator: "\n")
        }
        return .result(value: summary)
    }
}

struct GetNextBead: AppIntent {
    static var title: LocalizedStringResource = "Get Next Bead"
    static var description = IntentDescription(
        "The single highest-scoring bead that is ready to work on.")

    @Parameter(title: "Workspace")
    var workspace: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let answer = try await withSession(workspace) { engine in
            let triage = try await engine.triage()
            // Gated on the engine's actionable set, not merely on rank. A
            // recommendation can be graph-important while still blocked, and
            // offering one as "next" would send an agent at work it cannot
            // start.
            let actionable = try await engine.actionableIDs()
            guard let pick = triage.recommendations.first(where: { actionable.contains($0.id) })
            else {
                return "Nothing is actionable."
            }
            return "\(pick.id) — \(pick.title)"
        }
        return .result(value: answer)
    }
}

struct GetExecutionPlan: AppIntent {
    static var title: LocalizedStringResource = "Get Execution Plan"
    static var description = IntentDescription(
        "Parallel tracks of work that respect the dependency graph.")

    @Parameter(title: "Workspace")
    var workspace: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = try await withSession(workspace) { engine in
            let plan = try await engine.executionPlan()
            guard !plan.tracks.isEmpty else { return "No work is ready." }
            return plan.tracks
                .map { track in
                    let items = track.items.map(\.id).joined(separator: ", ")
                    return "\(track.id): \(items)"
                }
                .joined(separator: "\n")
        }
        return .result(value: summary)
    }
}

struct GetAlerts: AppIntent {
    static var title: LocalizedStringResource = "Get Alerts"
    static var description = IntentDescription(
        "Health alerts, worst first. Optionally narrowed to one severity.")

    @Parameter(title: "Workspace")
    var workspace: String?

    @Parameter(title: "Severity")
    var severity: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = try await withSession(workspace) { engine in
            let severityFilter = severity.flatMap { AlertSeverity(rawValue: $0) }
            let report = try await engine.alerts(severity: severityFilter)
            guard !report.alerts.isEmpty else { return "No alerts." }
            return report.grouped
                .flatMap { group in
                    group.alerts.map { "[\(group.severity.rawValue)] \($0.message)" }
                }
                .joined(separator: "\n")
        }
        return .result(value: summary)
    }
}

struct ForecastBead: AppIntent {
    static var title: LocalizedStringResource = "Forecast Bead"
    static var description = IntentDescription(
        "When one bead is likely to be finished, given a number of agents.")

    @Parameter(title: "Bead ID")
    var beadID: String

    @Parameter(title: "Workspace")
    var workspace: String?

    @Parameter(title: "Agents", default: 1)
    var agents: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = try await withSession(workspace) { engine in
            let data = try await engine.rawJSON(
                "eta", request: ["id": beadID, "agents": max(agents, 1)])
            struct Estimate: Decodable {
                var estimatedDays: Double
                var confidence: Double
                private enum CodingKeys: String, CodingKey {
                    case estimatedDays = "estimated_days"
                    case confidence
                }
            }
            let estimate = try JSONDecoder().decode(Estimate.self, from: data)
            return String(
                format: "%@: about %.1f days (confidence %.0f%%)",
                beadID, estimate.estimatedDays, estimate.confidence * 100)
        }
        return .result(value: summary)
    }
}

/// bv's `--export-format`, for the Shortcuts parameter.
enum ReportFormatOption: String, AppEnum {
    case markdown, json, csv, mermaid

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Report Format"
    static var caseDisplayRepresentations: [ReportFormatOption: DisplayRepresentation] = [
        .markdown: "Markdown", .json: "JSON", .csv: "CSV", .mermaid: "Mermaid",
    ]
}

struct ExportReport: AppIntent {
    static var title: LocalizedStringResource = "Export Report"
    static var description = IntentDescription(
        "The workspace's report as Markdown, JSON, CSV or a Mermaid graph.")

    @Parameter(title: "Workspace")
    var workspace: String?

    @Parameter(title: "Format", default: .markdown)
    var format: ReportFormatOption

    @Parameter(title: "Title", default: "Bead Report")
    var reportTitle: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let request = ReportRequest(
            format: ReportFormat(rawValue: format.rawValue), title: reportTitle)
        let content = try await withSession(workspace) { engine in
            try await engine.exportReport(request).content
        }
        return .result(value: content)
    }
}

/// The Shortcuts gallery entries.
struct VBXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetNextBead(),
            phrases: ["What should I work on in \(.applicationName)"],
            shortTitle: "Next Bead",
            systemImageName: "bolt.circle")
        AppShortcut(
            intent: GetTriage(),
            phrases: ["Triage my beads in \(.applicationName)"],
            shortTitle: "Triage",
            systemImageName: "list.number")
        AppShortcut(
            intent: GetAlerts(),
            phrases: ["Show bead alerts in \(.applicationName)"],
            shortTitle: "Alerts",
            systemImageName: "bell.badge")
    }
}
