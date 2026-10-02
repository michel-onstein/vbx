import VBXCore
import CVBXEngine
import Foundation

/// Errors surfaced across the engine boundary.
public enum EngineError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case callFailed(method: String, message: String)
    case decodeFailed(method: String, underlying: String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): "Could not open workspace: \(m)"
        case .callFailed(let method, let m): "Engine call \(method) failed: \(m)"
        case .decodeFailed(let method, let u): "Could not decode \(method) response: \(u)"
        case .notOpen: "No workspace is open."
        }
    }
}

/// What the engine says about readiness, beyond the ready set itself.
public struct Readiness: Sendable, Equatable {
    /// Ids the engine reports as actionable.
    public var actionable: Set<String>
    /// Ids a `defer_until` still in the future withholds from Ready, at the
    /// engine's pinned clock. Swift never compares the date itself.
    public var deferred: Set<String>

    public init(actionable: Set<String> = [], deferred: Set<String> = []) {
        self.actionable = actionable
        self.deferred = deferred
    }
}

/// The envelope every C entry point returns.
private struct Envelope: Decodable {
    var ok: Bool
    var error: String?
    var handle: Int64?
    var data: JSONValueBox?
}

/// Holds `data` as raw bytes so each caller can decode it into its own type.
private struct JSONValueBox: Decodable {
    let raw: Data
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode whatever shape arrived; the concrete type is the caller's
        // business, and this keeps one generic decode path.
        let any = try container.decode(AnyCodable.self)
        raw = try JSONSerialization.data(withJSONObject: any.value, options: [.fragmentsAllowed])
    }
}

private struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        } else if let v = try? c.decode([AnyCodable].self) {
            value = v.map(\.value)
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Int.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else {
            value = NSNull()
        }
    }
}

/// An open bead workspace, backed by bv's Go analysis engine running
/// in-process.
///
/// Actor-isolated because the underlying session is a single handle: calls are
/// serialised here, while the concurrency that matters (the two-phase
/// analyser's worker pool) lives inside Go.
public actor BeadsEngine {
    private var handle: Int64?

    public init() {}

    deinit {
        if let handle { vbx_close(handle) }
    }

    /// Opens a workspace directory, `.beads` directory, or data file.
    ///
    /// Returns once Phase-1 metrics are ready; Phase 2 continues in the
    /// background and is observable through ``metrics()``.
    ///
    /// `liveTrackerActions` lets the engine resolve each bead's live tracker,
    /// so triage and the next bead carry runnable `br show` and
    /// `br update --claim` commands. Resolving it runs `br` as a subprocess,
    /// which the App Sandbox forbids — so only `vbx-cli` passes `true`, and in
    /// the app every bead's actions carry the reason they are unavailable
    /// instead. See ADR-020.
    ///
    /// `exportHooks` runs the project's `.bv/hooks.yaml` around a report
    /// `export_report` writes to disk, as `bv --export` does. A hook is a
    /// repository-configured shell command — the same subprocess the sandbox
    /// forbids — so only `vbx-cli` passes `true`, and not under `--no-hooks`.
    ///
    /// `workspace` names a `.bv/workspace.yaml` to load as given, skipping
    /// discovery from `path` — `bv --workspace`, which only `vbx-cli` passes.
    /// Without it, `path` is discovered by bv's precedence: a reachable
    /// `.beads` wins over a workspace configuration above it. See ADR-026.
    ///
    /// `feedbackCommand` opens `path` the way bv answers its feedback flags:
    /// before any workspace discovery, with `workspace` ignored, and with
    /// `feedback.json` in the beads directory bv resolves for `path`. A load
    /// that fails does not fail the open — bv's show and reset never load —
    /// but fails a recorded verdict, with bv's text. Only `vbx-cli` passes it.
    ///
    /// `feedbackFromPath` reads `feedback.json` where bv's robot commands do:
    /// in the beads directory bv resolves for `path` as the working directory,
    /// whichever graph was loaded — so from a folder below a workspace root,
    /// the folder's own `.beads`, not the root's. Only `vbx-cli` passes it.
    /// The app leaves it off: it opens a workspace by its configuration, and
    /// shows and records feedback in the root's `.beads` (vbx-15s, ADR-026).
    ///
    /// `idPatterns` are bv's `--id-pattern` values: extra bead-id regexes the
    /// history's explicit-id strategy and orphan detector recognise. One that
    /// does not compile fails the open with bv's text, `Invalid --id-pattern
    /// …`, before anything is read. Only `vbx-cli` passes them.
    ///
    /// `idPatternsFromPrefix` registers one pattern per id prefix the
    /// workspace declares (`.beads/config.yaml`'s `issue_prefix`, or each
    /// workspace member's prefix), so a commit naming a `br`-minted id such as
    /// `vbx-8ou` is linked. bv has no such default; it is the app's, which has
    /// no command line to pass `--id-pattern` on (ADR-027). `vbx-cli` leaves
    /// it off and answers as bv does.
    public func open(
        path: String, skipPhase2: Bool = false, liveTrackerActions: Bool = false,
        exportHooks: Bool = false, workspace: String? = nil, feedbackCommand: Bool = false,
        feedbackFromPath: Bool = false, idPatterns: [String] = [],
        idPatternsFromPrefix: Bool = false
    ) throws -> WorkspaceInfo {
        close()

        var config =
            [
                "path": path, "skip_phase2": skipPhase2,
                "live_tracker_actions": liveTrackerActions,
                "export_hooks": exportHooks,
            ] as [String: Any]
        if let workspace { config["workspace"] = workspace }
        if feedbackCommand { config["feedback_command"] = true }
        if feedbackFromPath { config["feedback_from_path"] = true }
        if !idPatterns.isEmpty { config["id_patterns"] = idPatterns }
        if idPatternsFromPrefix { config["id_patterns_from_prefix"] = true }
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(decoding: configData, as: UTF8.self)

        let envelope = try configString.withCString { cfg -> Envelope in
            guard let result = vbx_open(UnsafeMutablePointer(mutating: cfg)) else {
                throw EngineError.openFailed("engine returned no response")
            }
            defer { vbx_free(result) }
            return try Self.decodeEnvelope(from: result)
        }

        guard envelope.ok, let h = envelope.handle else {
            throw EngineError.openFailed(envelope.error ?? "unknown error")
        }
        handle = h
        return try call("info", as: WorkspaceInfo.self)
    }

    public func close() {
        if let h = handle {
            vbx_close(h)
            handle = nil
        }
    }

    public var isOpen: Bool { handle != nil }

    // MARK: - Typed methods

    public func info() throws -> WorkspaceInfo { try call("info", as: WorkspaceInfo.self) }

    public func issues() throws -> [Issue] {
        try call("issues", as: IssuesResponse.self).issues
    }

    public func metrics() throws -> GraphMetrics { try call("metrics", as: GraphMetrics.self) }

    /// Blocks inside the engine until Phase 2 finishes, then returns the
    /// complete metrics. Call from a background task; never from the main actor.
    public func waitForPhase2() throws -> GraphMetrics {
        try call("wait_phase2", as: GraphMetrics.self)
    }

    /// Forces a full re-analysis with every metric enabled.
    ///
    /// Needed when the session was opened with `skipPhase2`, or when a metric
    /// timed out: those states are "ready" with no values, so waiting again
    /// would never produce anything.
    public func computeFullMetrics() throws -> GraphMetrics {
        try call("compute_phase2", as: GraphMetrics.self)
    }

    public func reload() throws -> WorkspaceInfo { try call("reload", as: WorkspaceInfo.self) }

    public func actionableIDs() throws -> Set<String> {
        try readiness().actionable
    }

    /// The ready set and the beads a future `defer_until` withholds, read in
    /// one call at one pinned instant so the two cannot disagree about "now".
    public func readiness() throws -> Readiness {
        let response = try call("actionable", as: ActionableResponse.self)
        return Readiness(actionable: Set(response.ids), deferred: Set(response.deferred ?? []))
    }

    /// The execution plan. A `label` plans bv's label scope — the label's
    /// beads and their direct dependency neighbours, with only the labelled
    /// beads offered as work.
    public func executionPlan(label: String? = nil) throws -> ExecutionPlan {
        try call("plan", request: Self.labelScope(label), as: ExecutionPlan.self)
    }

    /// The request carrying bv's global `--label` scope, or nil for the whole
    /// project. The engine applies it in one place for every method that
    /// accepts it.
    static func labelScope(_ label: String?) -> [String: Any]? {
        guard let label, !label.isEmpty else { return nil }
        return ["label": label]
    }

    public func graphEdges() throws -> [GraphEdge] {
        try call("graph", as: GraphResponse.self).edges
    }

    public func unblocks(_ id: String) throws -> [String] {
        try call("unblocks", request: ["id": id], as: UnblocksResponse.self).unblocks
    }

    /// What to work on next. A `label` ranks within bv's label scope, as
    /// `executionPlan(label:)` does.
    public func triage(label: String? = nil) throws -> Triage {
        try call("triage", request: Self.labelScope(label), as: Triage.self)
    }

    // MARK: - Triage feedback

    /// The feedback on disk, as `bv --feedback-show` reports it. Writes
    /// nothing.
    public func triageFeedback() throws -> TriageFeedbackResult {
        try call("triage_feedback", as: TriageFeedbackResult.self)
    }

    /// Records a verdict on one bead into `.beads/feedback.json`, scored by
    /// the engine as `bv --feedback-accept` / `--feedback-ignore` scores it.
    ///
    /// The session's own copy of the feedback is deliberately not refreshed:
    /// the reload that follows sees the file changed, and re-ranks.
    @discardableResult
    public func recordTriageFeedback(
        id: String, verdict: TriageVerdict
    ) throws -> TriageFeedbackResult {
        try call(
            "triage_feedback_record", request: ["id": id, "action": verdict.rawValue],
            as: TriageFeedbackResult.self)
    }

    /// Drops every verdict, as `bv --feedback-reset` does.
    @discardableResult
    public func resetTriageFeedback() throws -> TriageFeedbackResult {
        try call("triage_feedback_reset", as: TriageFeedbackResult.self)
    }

    public func labelHealth() throws -> LabelAnalysis {
        try call("label_health", as: LabelAnalysis.self)
    }

    /// Cross-label dependency flow: which label blocks which, and how hard.
    public func labelFlow() throws -> LabelFlow {
        try call("label_flow", as: LabelFlow.self)
    }

    /// Labels ranked by attention needed, each with its score decomposition.
    public func labelAttention() throws -> LabelAttention {
        try call("label_attention", as: LabelAttention.self)
    }

    /// Renders a report the way `bv --export` does: markdown, json, csv or
    /// mermaid, with a recipe's export defaults under the explicit options.
    ///
    /// The content is always returned; `path` additionally writes it, which the
    /// CLI uses. The app writes it itself, through the save panel's URL, so it
    /// keeps working under the App Sandbox.
    public func exportReport(_ options: ReportRequest = ReportRequest(), path: String? = nil)
        throws -> ReportExport
    {
        var request: [String: Any] = [:]
        if let value = options.format { request["format"] = value.rawValue }
        if let value = options.includeGraph { request["include_graph"] = value }
        if let value = options.template { request["template"] = value }
        if let value = options.recipe { request["recipe"] = value }
        if let value = options.label { request["label"] = value }
        if let value = options.title { request["title"] = value }
        if let path { request["path"] = path }
        return try call("export_report", request: request, as: ReportExport.self)
    }

    // MARK: - Git correlation
    //
    // bv's own correlator, whose git calls the engine answers from the object
    // store, so these work under the App Sandbox where a `git` subprocess
    // would not (ADR-027). The first call walks the history and is slow; the
    // engine caches the walk until HEAD moves or the bead set changes. Each
    // request key is named after the bv flag it carries.

    /// The whole bead-to-commit correlation report. `limit` is bv's
    /// --history-limit, the commits walked; 0 keeps bv's default of 500.
    public func history(limit: Int = 0, refresh: Bool = false) throws -> HistoryReport {
        try call("history", request: request(limit: limit, refresh: refresh), as: HistoryReport.self)
    }

    /// One bead's causal chain and the insights drawn from it.
    public func causality(_ id: String) throws -> CausalityResult {
        try call("causality", request: ["id": id], as: CausalityResult.self)
    }

    /// Beads that touched the same files, commits or window as `id`, at most
    /// `limit` per category (bv's --related-max-results; 0 keeps its 10).
    public func relatedWork(_ id: String, limit: Int = 0) throws -> RelatedWork {
        var req: [String: Any] = ["id": id]
        if limit > 0 { req["related_max_results"] = limit }
        return try call("related", request: req, as: RelatedWork.self)
    }

    /// Which beads have touched a file. A path containing `*`, `?` or `[` is
    /// treated as a glob.
    public func beads(touching path: String) throws -> FileBeadLookup {
        try call("file_beads", request: ["path": path], as: FileBeadLookup.self)
    }

    /// Files ranked by how many beads have touched them.
    public func fileHotspots(limit: Int = 25) throws -> FileHotspots {
        try call("file_hotspots", request: ["hotspots_limit": limit], as: FileHotspots.self)
    }

    /// Files that change alongside `path`.
    public func fileRelations(
        _ path: String, threshold: Double = 0.3, limit: Int = 20
    ) throws -> CoChangeResult {
        try call(
            "file_relations",
            request: ["path": path, "relations_threshold": threshold, "relations_limit": limit],
            as: CoChangeResult.self)
    }

    /// Commits no bead accounts for that bv's detector scores at 30 or more
    /// (its --orphans-min-score default), within the walked window.
    public func orphanCommits(limit: Int = 0) throws -> OrphanReport {
        try call("orphans", request: request(limit: limit, refresh: false), as: OrphanReport.self)
    }

    // MARK: - Static site export

    /// Builds a deployable static bundle.
    public func exportSite(
        outputDir: String, title: String,
        includeRobotOutputs: Bool = true, interactiveGraph: Bool = true,
        githubWorkflow: Bool = false
    ) throws -> SiteBundle {
        try call(
            "export_site",
            request: [
                "output_dir": outputDir, "title": title,
                "include_robot_outputs": includeRobotOutputs,
                "interactive_graph": interactiveGraph,
                "github_workflow": githubWorkflow,
            ],
            as: SiteBundle.self)
    }

    /// Serves a built bundle locally. The server runs in-process.
    public func previewSite(bundlePath: String, port: Int = 0) throws -> SitePreview {
        try call(
            "export_preview",
            request: ["bundle_path": bundlePath, "port": port],
            as: SitePreview.self)
    }

    /// Publishes a bundle to GitHub Pages.
    ///
    /// The token comes from the caller — the Keychain — rather than the
    /// environment, and the whole flow runs in-process: the repository is
    /// created through the API, the bundle pushed with go-git, Pages enabled
    /// through the API again.
    public func deployToGitHub(
        bundlePath: String, repo: String, token: String,
        isPrivate: Bool = false, branch: String = "gh-pages"
    ) throws -> SiteDeployment {
        try call(
            "export_deploy_github",
            request: [
                "bundle_path": bundlePath, "repo": repo, "token": token,
                "private": isPrivate, "branch": branch,
            ],
            as: SiteDeployment.self)
    }

    /// What to run for a Cloudflare deployment, which needs `wrangler`.
    public func cloudflareInstructions(
        bundlePath: String, project: String
    ) throws -> DeployInstructions {
        try call(
            "export_cloudflare_hint",
            request: ["bundle_path": bundlePath, "project": project],
            as: DeployInstructions.self)
    }

    // MARK: - Repositories

    /// The repositories this workspace aggregates, and the dependencies that
    /// cross between them.
    public func repos() throws -> RepoList {
        try call("repos", as: RepoList.self)
    }

    // MARK: - Search

    /// Runs one query.
    ///
    /// The default embedder is bv's deterministic `hash` one. A better
    /// embedder gives better results and *different* ones, so choosing it is
    /// the caller's decision — the default keeps vbx's ranking identical to
    /// the CLI's.
    public func search(
        _ query: String, mode: SearchMode = .text, limit: Int = 20,
        preset: String? = nil, weights: SearchWeights? = nil
    ) throws -> SearchResults {
        var req: [String: Any] = ["query": query, "mode": mode.rawValue, "limit": limit]
        if let weights {
            req["weights"] = weights.asDictionary
        } else if let preset, !preset.isEmpty {
            req["preset"] = preset
        }
        return try call("search", request: req, as: SearchResults.self)
    }

    /// The weight presets and the modes available.
    public func searchPresets() throws -> SearchPresetList {
        try call("search_presets", as: SearchPresetList.self)
    }

    // MARK: - Sprints

    public func sprints() throws -> SprintList {
        try call("sprint_list", as: SprintList.self)
    }

    /// One sprint's burndown. Pass `current` for the active sprint.
    public func burndown(sprintID: String = "current") throws -> Burndown {
        try call("burndown", request: ["id": sprintID], as: Burndown.self)
    }

    /// How long the open work takes with `agents` working in parallel.
    ///
    /// `capacityLabel` is bv's `--capacity-label`: it simulates only the beads
    /// carrying exactly that label.
    public func capacity(agents: Int, capacityLabel: String? = nil) throws -> Capacity {
        var req: [String: Any] = ["agents": agents]
        if let capacityLabel, !capacityLabel.isEmpty { req["capacity_label"] = capacityLabel }
        return try call("capacity", request: req, as: Capacity.self)
    }

    // MARK: - Recipes

    /// Every recipe, built-in and project-defined.
    public func recipes() throws -> RecipeList {
        try call("recipes", as: RecipeList.self)
    }

    /// The beads a recipe selects, in the order it sorts them.
    ///
    /// Applied in the engine so one implementation decides what a recipe
    /// means — the same one `bv --recipe` uses.
    public func applyRecipe(named name: String) throws -> AppliedRecipe {
        try call("recipe_apply", request: ["name": name], as: AppliedRecipe.self)
    }

    /// Writes a project recipe into `<project>/.bv/recipes.yaml` — or, for one
    /// defined by its own `.beads/recipes` file, back into that file, which
    /// would otherwise shadow the edit.
    public func saveRecipe(_ recipe: Recipe) throws {
        let encoded = try JSONEncoder().encode(recipe)
        let object = try JSONSerialization.jsonObject(with: encoded)
        _ = try invoke("recipe_save", request: ["recipe": object])
    }

    public func deleteRecipe(named name: String) throws {
        _ = try invoke("recipe_delete", request: ["name": name])
    }

    // MARK: - Alerts and drift

    /// Health alerts, optionally narrowed.
    ///
    /// Works with or without a saved baseline: without one the delta checks
    /// have nothing to compare, but the checks that read the issue list —
    /// staleness, blocking cascades — still run.
    ///
    /// `alertLabel` is bv's `--alert-label`: it keeps only alerts that name
    /// the label — on their issue, as their own label, or in a detail line —
    /// so workspace-wide alerts drop out under it.
    public func alerts(
        severity: AlertSeverity? = nil, type: String? = nil, alertLabel: String? = nil
    ) throws -> AlertReport {
        var req: [String: Any] = [:]
        if let severity { req["severity"] = severity.rawValue }
        if let type, !type.isEmpty { req["type"] = type }
        if let alertLabel, !alertLabel.isEmpty { req["alert_label"] = alertLabel }
        return try call("alerts", request: req.isEmpty ? nil : req, as: AlertReport.self)
    }

    /// The saved baseline, if there is one.
    public func baselineInfo() throws -> BaselineInfo {
        try call("baseline_info", as: BaselineInfo.self)
    }

    /// Records the current graph as the point drift is measured from.
    @discardableResult
    public func saveBaseline(description: String) throws -> BaselineInfo {
        try call("baseline_save", request: ["description": description], as: BaselineInfo.self)
    }

    // MARK: - Time travel

    /// Commits that changed the beads file, newest first.
    public func revisions(limit: Int = 50) throws -> RevisionList {
        try call("revisions", request: ["limit": limit], as: RevisionList.self)
    }

    /// The bead set as of `revision` — any expression git accepts.
    public func snapshot(at revision: String) throws -> WorkspaceSnapshot {
        try call("snapshot_at", request: ["revision": revision], as: WorkspaceSnapshot.self)
    }

    /// The current bead set compared against `revision`.
    public func diff(since revision: String) throws -> TimeTravelDiff {
        try call("diff", request: ["revision": revision], as: TimeTravelDiff.self)
    }

    /// One commit's unified diff, optionally narrowed to a single file.
    ///
    /// Rendered from the object store, so it works where `git diff` cannot.
    public func commitPatch(sha: String, path: String? = nil) throws -> CommitPatch {
        var req: [String: Any] = ["sha": sha]
        if let path, !path.isEmpty { req["path"] = path }
        return try call("commit_patch", request: req, as: CommitPatch.self)
    }

    /// Every recorded verdict on a commit-to-bead link, and the accuracy stats.
    public func correlationFeedback() throws -> CorrelationFeedbackReport {
        try call("correlation_feedback", as: CorrelationFeedbackReport.self)
    }

    /// Confirms a link. The link is raised to the top of its method's
    /// confidence band and the verdict is recorded for future reports.
    @discardableResult
    public func confirmCorrelation(
        sha: String, beadID: String, reason: String = ""
    ) throws -> CorrelationVerdict {
        try call(
            "correlation_confirm",
            request: ["sha": sha, "bead_id": beadID, "reason": reason],
            as: CorrelationVerdict.self)
    }

    /// Rejects a link, removing it from the report entirely.
    @discardableResult
    public func rejectCorrelation(
        sha: String, beadID: String, reason: String = ""
    ) throws -> CorrelationVerdict {
        try call(
            "correlation_reject",
            request: ["sha": sha, "bead_id": beadID, "reason": reason],
            as: CorrelationVerdict.self)
    }

    private func request(limit: Int, refresh: Bool) -> [String: Any] {
        var req: [String: Any] = [:]
        if limit > 0 { req["history_limit"] = limit }
        if refresh { req["refresh"] = true }
        return req
    }

    /// Raw JSON for methods vbx surfaces but does not yet model, such as
    /// `triage`, `impact`, `label_health` and `eta`.
    public func rawJSON(_ method: String, request: [String: Any]? = nil) throws -> Data {
        try invoke(method, request: request)
    }

    // MARK: - Probing without opening

    /// Reports whether `path` holds bead data, without loading it.
    ///
    /// Static and synchronous on purpose. `NSOpenPanel` asks
    /// `panel(_:shouldEnable:)` about every directory it draws and expects an
    /// answer on the spot, so this cannot be an `await` on an actor — and it
    /// must not open a session, which would run a full analysis to answer a
    /// yes/no question.
    ///
    /// The answer comes from the same code discovery uses, so the panel and
    /// the loader cannot disagree: what the panel offers, ``open(path:skipPhase2:)``
    /// accepts.
    public static func probe(path: String) throws -> ProbeResult {
        let envelope = try path.withCString { p -> Envelope in
            guard let result = vbx_probe(UnsafeMutablePointer(mutating: p)) else {
                throw EngineError.callFailed(method: "probe", message: "no response")
            }
            defer { vbx_free(result) }
            return try decodeEnvelope(from: result)
        }

        guard envelope.ok, let box = envelope.data else {
            throw EngineError.callFailed(
                method: "probe", message: envelope.error ?? "unknown error")
        }
        do {
            return try decoder.decode(ProbeResult.self, from: box.raw)
        } catch {
            throw EngineError.decodeFailed(method: "probe", underlying: String(describing: error))
        }
    }

    // MARK: - Plumbing

    private struct IssuesResponse: Decodable { var issues: [Issue] }
    private struct ActionableResponse: Decodable {
        var ids: [String]
        var deferred: [String]?
    }
    private struct GraphResponse: Decodable { var edges: [GraphEdge] }
    private struct UnblocksResponse: Decodable { var unblocks: [String] }

    private func call<T: Decodable>(
        _ method: String, request: [String: Any]? = nil, as type: T.Type
    ) throws -> T {
        let data = try invoke(method, request: request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw EngineError.decodeFailed(method: method, underlying: String(describing: error))
        }
    }

    private func invoke(_ method: String, request: [String: Any]?) throws -> Data {
        guard let h = handle else { throw EngineError.notOpen }

        var requestString = ""
        if let request {
            let d = try JSONSerialization.data(withJSONObject: request)
            requestString = String(decoding: d, as: UTF8.self)
        }

        let envelope: Envelope = try method.withCString { m in
            try requestString.withCString { r in
                guard
                    let result = vbx_call(
                        h,
                        UnsafeMutablePointer(mutating: m),
                        requestString.isEmpty ? nil : UnsafeMutablePointer(mutating: r)
                    )
                else {
                    throw EngineError.callFailed(method: method, message: "no response")
                }
                // Freed on every path, including the throwing ones, so a
                // failed call cannot leak the engine's malloc'd buffer.
                defer { vbx_free(result) }
                return try Self.decodeEnvelope(from: result)
            }
        }

        guard envelope.ok else {
            throw EngineError.callFailed(method: method, message: envelope.error ?? "unknown error")
        }
        guard let box = envelope.data else { return Data("{}".utf8) }
        return box.raw
    }

    private static func decodeEnvelope(from cString: UnsafeMutablePointer<CChar>) throws -> Envelope {
        let data = Data(String(cString: cString).utf8)
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601WithFraction.date(from: raw) { return date }
            if let date = iso8601Plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unrecognised date \(raw)")
            )
        }
        return d
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain = ISO8601DateFormatter()
}
