import AppKit
import UniformTypeIdentifiers
import VBXCore
import VBXEngine
import Combine
import SwiftUI

/// The view surfaces in the sidebar.
public enum ViewSurface: String, CaseIterable, Identifiable, Sendable {
    case list, board, graph, tree, insights, plan, labels, flow, attention, history, alerts, sprint

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .list: "List"
        case .board: "Board"
        case .graph: "Graph"
        case .tree: "Tree"
        case .insights: "Insights"
        case .plan: "Plan"
        case .labels: "Labels"
        case .flow: "Flow"
        case .attention: "Attention"
        case .history: "History"
        case .alerts: "Alerts"
        case .sprint: "Sprint"
        }
    }

    public var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .tree: "list.bullet.indent"
        case .insights: "chart.bar.xaxis"
        case .plan: "flowchart"
        case .labels: "tag"
        case .flow: "square.grid.3x3"
        case .attention: "exclamationmark.bubble"
        case .history: "clock.arrow.circlepath"
        case .alerts: "bell.badge"
        case .sprint: "chart.line.downtrend.xyaxis"
        }
    }

    /// Command-key equivalent. bv's own single-letter binding is applied
    /// separately by the terminal-keys layer.
    public var keyEquivalent: KeyEquivalent {
        switch self {
        case .list: "1"
        case .board: "2"
        case .graph: "3"
        case .tree: "4"
        case .insights: "5"
        case .plan: "6"
        case .labels: "7"
        case .flow: "8"
        case .attention: "9"
        case .history: "0"
        case .alerts: "-"
        case .sprint: "="
        }
    }

    /// Whether the toolbar's Filter picker and Sort menu belong on this
    /// surface.
    ///
    /// Both controls write to ``ProjectStore/query``, which is read in exactly
    /// one place — `visibleIssues`. A surface that renders an engine payload of
    /// its own never consults it, so the controls sit there answering nothing:
    /// changing either one produces no visible effect at all. They are hidden
    /// rather than disabled, because a disabled control still claims the view
    /// has an ordering that happens to be unavailable, and these views have no
    /// bead ordering to begin with.
    ///
    /// This is a question about the toolbar, not a claim about the data: it is
    /// deliberately not derived from whether the view reads `visibleIssues`, so
    /// a surface can be left showing the controls while what it should do is
    /// still being decided.
    ///
    /// ``history`` was the one such case, and the answer was to drop them. It
    /// reads `store.history` and consults neither `query` nor `visibleIssues`,
    /// so both controls were as inert there as on the seven below. Giving it a
    /// filter and sort meaning something in its own terms — narrowing the
    /// commit walk, ordering the correlated beads — would be a feature nobody
    /// has asked for, and inventing one to justify a control already on screen
    /// is the wrong way round. If a real need appears it arrives as its own
    /// request, with its own idea of what filtering a history means.
    public var showsFilterAndSort: Bool {
        switch self {
        case .list, .board, .graph, .tree: true
        case .insights, .plan, .labels, .flow, .attention, .alerts, .sprint, .history: false
        }
    }

    /// bv's single-key shortcut for this surface.
    public var terminalKey: Character {
        switch self {
        case .list: "l"
        case .board: "b"
        case .graph: "g"
        case .tree: "E"
        case .insights: "i"
        case .plan: "p"
        case .labels: "]"
        case .flow: "F"
        case .attention: "A"
        case .history: "t"
        case .alerts: "!"
        case .sprint: "S"
        }
    }
}

/// Observable application state for one workspace.
@MainActor
public final class ProjectStore: ObservableObject {
    @Published public private(set) var issues: [Issue] = []
    @Published public private(set) var metrics: GraphMetrics = .empty
    @Published public private(set) var actionable: Set<String> = []
    @Published public private(set) var plan: ExecutionPlan = .empty
    @Published public private(set) var edges: [GraphEdge] = []
    @Published public private(set) var labelAnalysis: LabelAnalysis = .empty
    @Published public private(set) var labelFlow: LabelFlow = .empty
    @Published public private(set) var labelAttention: LabelAttention = .empty
    @Published public private(set) var triage: Triage = .empty
    @Published public private(set) var info: WorkspaceInfo?
    @Published public private(set) var loadError: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var phase2InFlight = false

    @Published public var surface: ViewSurface = .list {
        didSet {
            guard surface != oldValue else { return }
            recordNavigation()
        }
    }
    @Published public var query = IssueQuery()

    // MARK: Navigation history
    //
    // Where the user has been, so back and forward can return. See
    // ``NavigationEntry`` for what counts as a position and why plain row
    // selection does not push one.

    /// Visited positions, oldest first, capped at ``navigationHistoryLimit``.
    @Published public internal(set) var navigationHistory: [NavigationEntry] = []

    /// Index into ``navigationHistory`` of where the user is now.
    ///
    /// A cursor rather than a stack pointer: going back moves it down and
    /// leaves the entries above intact, which is the only reason forward has
    /// anywhere to go.
    @Published public internal(set) var navigationCursor: Int = -1

    /// True while an entry is being restored.
    ///
    /// Restoring writes `surface` and `selection`, which are the very things
    /// that record history — without this, going back would record the arrival
    /// as a fresh navigation and forward would be truncated away instantly.
    var isRestoringNavigation = false

    /// True while ``select(id:)`` is deliberately jumping to a bead.
    ///
    /// A jump always records a position of its own and never coalesces: two
    /// bead links followed in quick succession are two deliberate moves, not
    /// one run of browsing.
    var isJumpingToBead = false

    /// When the last selection-driven position was recorded.
    ///
    /// Only used to decide whether a selection continues the previous run —
    /// see ``noteFocusChanged()``.
    var lastSelectionRecordedAt: Date?

    /// The clock the coalescing window is measured against.
    ///
    /// Injected so tests can drive a run of selections deterministically
    /// instead of racing a real interval.
    var navigationClock: () -> Date = Date.init

    /// Workspaces opened recently, for the File menu. Written by
    /// ``open(path:)`` once a load has actually succeeded.
    ///
    /// Defaults to the shared list because the menu is app-wide: every window
    /// contributes to one history. Tests substitute their own so they never
    /// write into real preferences.
    @Published public var recents = RecentWorkspaces.shared

    /// The only thing that writes bead data. See ``BeadWriter`` for why it
    /// goes through `br` rather than touching the JSONL.
    @Published public var writer = BeadWriter()

    /// Every selected bead. Bound directly to the list's `Table`.
    ///
    /// A set rather than a single id, because the table supports shift- and
    /// command-click. Most of the app still means *one* bead, and reaches for
    /// ``focusedID`` or ``select(id:)`` instead.
    @Published public var selection: Set<Issue.ID> = [] {
        didSet { updateFocus(from: oldValue) }
    }

    /// The one bead the inspector shows and `j`/`k` move between.
    ///
    /// Distinct from the selection because a `Set` has no order: with three
    /// beads selected, "the first" is whichever the hash happens to yield, and
    /// the inspector would appear to jump around. This follows the bead most
    /// recently added instead, which is the one just clicked.
    @Published public private(set) var focusedID: Issue.ID?
    @Published public var terminalKeysEnabled = true
    @Published public var skipPhase2 = false
    @Published public private(set) var isWatching = false
    @Published public private(set) var lastReloadAt: Date?
    @Published public private(set) var lastExportPath: String?

    // MARK: Correlation
    //
    // History is loaded on demand rather than with the workspace: walking the
    // object store is the most expensive thing the engine does, and most
    // sessions never open the History view at all.
    @Published public private(set) var history: HistoryReport = .empty
    @Published public private(set) var orphans: OrphanReport = .empty
    @Published public private(set) var hotspots: FileHotspots = .empty
    @Published public private(set) var feedback: CorrelationFeedbackReport = .empty
    @Published public private(set) var historyLoaded = false
    @Published public private(set) var historyLoading = false
    /// Why history is unavailable — most often "not a git repository".
    @Published public private(set) var historyError: String?

    // MARK: Time travel
    //
    // Time travel is an overlay rather than a mode switch: the workspace's own
    // analysis stays on the current bead set, and the chosen revision supplies
    // a comparison. Swapping the loaded set wholesale would leave every metric
    // describing a graph that is no longer on screen.
    @Published public private(set) var revisions: RevisionList = .empty
    @Published public private(set) var timeTravel: TimeTravelDiff = .empty
    /// The historical bead set, for showing a bead as it was.
    @Published public private(set) var pastIssues: [String: Issue] = [:]
    @Published public private(set) var timeTravelLoading = false

    // MARK: Static site export
    @Published public private(set) var siteBundle: SiteBundle = .empty
    @Published public private(set) var sitePreview: SitePreview = .empty
    @Published public private(set) var siteDeployment: SiteDeployment = .empty
    @Published public private(set) var siteBusy = false
    @Published public private(set) var siteError: String?

    // MARK: Repositories
    @Published public private(set) var repos: RepoList = .empty
    /// Repositories the list is narrowed to. Empty means all of them.
    @Published public var repoFilter: Set<String> = []

    // MARK: Search
    //
    // The scope bar's mode. `.text` is the default because it is what the
    // fuzzy search in `IssueQuery` already approximates; hybrid is a
    // deliberate choice, because it reorders by things other than the words
    // you typed.
    @Published public var searchMode: SearchMode = .text
    @Published public var searchPreset: String = "default"
    @Published public var searchWeights: SearchWeights?
    @Published public private(set) var searchPresets: SearchPresetList = .empty
    @Published public private(set) var searchResults: SearchResults = .empty
    @Published public private(set) var searchInFlight = false

    // MARK: Sprints
    @Published public private(set) var sprints: SprintList = .empty
    @Published public private(set) var burndown: Burndown = .empty
    @Published public private(set) var capacity: Capacity = .empty
    @Published public private(set) var sprintError: String?
    /// Which sprint the dashboard is showing. Empty means the active one.
    @Published public var selectedSprintID: String = ""
    @Published public var capacityAgents: Int = 1

    // MARK: Recipes
    @Published public private(set) var recipes: RecipeList = .empty
    /// The recipe currently applied, if any.
    @Published public private(set) var activeRecipe: Recipe?
    /// The ids that recipe selected, in its order. Nil when none is applied.
    @Published public private(set) var recipeIDs: [String]?
    @Published public private(set) var recipeTruncated = false

    // MARK: Alerts
    @Published public private(set) var alerts: AlertReport = .empty
    @Published public private(set) var baseline: BaselineInfo = .empty
    @Published public var alertSeverityFilter: AlertSeverity?
    @Published public var alertTypeFilter: String?
    @Published public var alertLabelFilter: String?
    /// Deliver critical alerts as notifications while watching.
    @Published public var notifyOnCriticalAlerts = false

    private let engine = BeadsEngine()
    private let watcher = FileWatchService()

    /// Watches `.git` so a commit made outside vbx is noticed.
    ///
    /// The bead file does not change when someone commits — `HEAD` moves and
    /// every dirty bead becomes clean while the export sits untouched. The
    /// existing watch would never fire, and the list would keep marking rows
    /// that are now committed.
    private let gitWatcher = FileWatchService()
    private let notifier = AlertNotifier()
    private let spotlight = SpotlightIndexer()
    private var triageNeedsRefresh = false
    /// Unblocks lists already reported by the plan and triage, so the inspector
    /// can show the count immediately instead of flashing 0 while an async
    /// round-trip resolves.
    private var unblocksCache: [String: [String]] = [:]

    public init() {}

    public var isLoaded: Bool { info != nil }

    /// Issues after the active recipe or filter, search and sort.
    ///
    /// A recipe replaces the filter and the sort — that is what applying one
    /// means — but the search box still narrows, because searching within a
    /// recipe's results is the obvious thing to want and losing the recipe on
    /// the first keystroke is not.
    public var visibleIssues: [Issue] {
        narrowToRepos(unfilteredVisibleIssues)
    }

    private var unfilteredVisibleIssues: [Issue] {
        // Hybrid search replaces the ordering entirely: its whole point is to
        // rank by things other than the words typed, so re-sorting afterwards
        // would discard the ranking that was asked for.
        if isUsingEngineSearch {
            let byID = issuesByID
            return searchResults.rankedIDs.compactMap { byID[$0] }
        }
        guard let recipeIDs else {
            return query.apply(to: issues, actionable: actionable, metrics: metrics)
        }
        let byID = issuesByID
        let selected = recipeIDs.compactMap { byID[$0] }
        guard !query.searchText.isEmpty else { return selected }
        return IssueQuery.rank(selected, query: query.searchText)
    }

    /// Narrows to the selected repositories, if any are selected.
    ///
    /// Applied last, on top of whatever chose the set — so a recipe, a search
    /// and a repository selection compose instead of overriding each other.
    private func narrowToRepos(_ candidates: [Issue]) -> [Issue] {
        guard !repoFilter.isEmpty, repos.isWorkspace else { return candidates }
        return candidates.filter { issue in
            guard let repo = repos.repo(owning: issue.id) else { return false }
            return repoFilter.contains(repo.name)
        }
    }

    /// The repository a bead belongs to, in a multi-repository workspace.
    public func repo(of id: Issue.ID) -> RepoInfo? {
        repos.repo(owning: id)
    }

    /// True when this bead sits on a dependency that crosses repositories.
    public func isCrossRepo(_ id: Issue.ID) -> Bool {
        repos.crossRepoIDs.contains(id)
    }

    /// Toggles one repository in the filter.
    public func toggleRepo(_ name: String) {
        if repoFilter.contains(name) {
            repoFilter.remove(name)
        } else {
            repoFilter.insert(name)
        }
    }

    /// The bead the inspector shows: the focused one, not "the first
    /// selected", which a `Set` cannot meaningfully offer.
    public var selectedIssue: Issue? {
        guard let focusedID else { return nil }
        return issues.first { $0.id == focusedID }
    }

    /// Every selected bead, in on-screen order.
    public var selectedIssues: [Issue] {
        let byID = issuesByID
        return orderedSelection().compactMap { byID[$0] }
    }

    public var issuesByID: [String: Issue] {
        Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
    }

    /// Bead titles keyed by id, for linkifying ids mentioned in prose.
    ///
    /// Deliberately tolerant of a duplicate id — a multi-repository workspace
    /// can carry one — because a tooltip is not worth trapping over.
    public var beadTitles: [String: String] {
        Dictionary(issues.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Automation entry points

    /// Handles a `vbx://` URL, opening a workspace and selecting a bead.
    ///
    /// Returns whether anything was acted on, so a caller can fall back to the
    /// system for a URL that was not ours.
    @discardableResult
    public func open(url: URL) async -> Bool {
        guard let workspace = BeadURL.workspace(in: url) ?? BeadURL.bead(in: url).map({ _ in "" })
        else { return false }

        // A workspace switch has to finish before the bead can be selected —
        // the bead may not exist until it does.
        if !workspace.isEmpty, workspace != info?.source {
            await open(path: workspace)
        }
        if let bead = BeadURL.bead(in: url) {
            return select(id: bead)
        }
        return !workspace.isEmpty
    }

    /// Handles a Spotlight activation.
    @discardableResult
    public func openSpotlightItem(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = SpotlightIndexer.beadID(from: userInfo) else { return false }
        return select(id: id)
    }

    /// Publishes the loaded beads to Spotlight.
    public func updateSpotlightIndex() async {
        guard let info else { return }
        await spotlight.index(issues, workspace: info.source)
    }

    /// Selects `id` alone, if the workspace holds it. Returns whether it did.
    ///
    /// *Replaces* the selection rather than extending it. Every caller — an
    /// inline bead link, a `vbx://` URL, a Spotlight hit, a drilldown from the
    /// flow matrix, alerts or the sprint critical path — means "show me this
    /// one", and adding to a selection the user built by hand would be a
    /// surprising way to answer that.
    ///
    /// The membership guard is what keeps a stale reference — in prose, or in
    /// a URL from outside the app — from clearing the current selection.
    /// Open one label's beads in the list.
    ///
    /// Labels is one of the surfaces that no longer offers a filter control, so
    /// it is worth being explicit that this is not that control: it narrows to
    /// the label and clears the status filter to set up the view it is
    /// navigating *to*. Hiding a picker on a surface does not make the query
    /// read-only there.
    ///
    /// It lives here rather than in the button that calls it so the sequence
    /// can be tested — a test that re-typed these three lines would agree with
    /// itself no matter what the button did.
    public func showLabelInList(_ label: String) {
        query.labels = [label]
        query.filter = .all
        surface = .list
    }

    @discardableResult
    public func select(id: String) -> Bool {
        guard issues.contains(where: { $0.id == id }) else { return false }
        // Jumping, not browsing: the position being left keeps the bead it was
        // recorded with, and the arrival is pushed as a position of its own so
        // back returns to where the jump started.
        isJumpingToBead = true
        selection = [id]
        isJumpingToBead = false
        recordNavigation()
        // A jump ends any run of browsing: the next selection is a fresh move
        // and records its own position rather than replacing this one.
        lastSelectionRecordedAt = nil
        return true
    }

    /// True when `id` is part of the selection.
    public func isSelected(_ id: Issue.ID) -> Bool { selection.contains(id) }

    /// The ids as a single line, in on-screen order, joined with `", "`.
    ///
    /// Pure, so the joining and the ordering can be tested without a
    /// pasteboard.
    public func idList(for ids: Set<Issue.ID>) -> String {
        orderedSelection(ids).joined(separator: ", ")
    }

    /// Puts the ids on the general pasteboard.
    ///
    /// Returns what was written, or nil when there was nothing to write —
    /// copying an empty string would silently replace whatever the user had
    /// on the clipboard with nothing.
    @discardableResult
    public func copyIDs(_ ids: Set<Issue.ID>) -> String? {
        let text = idList(for: ids)
        guard !text.isEmpty else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    /// Keeps ``focusedID`` pointing at something sensible as the set changes.
    private func updateFocus(from previous: Set<Issue.ID>) {
        if let added = selection.subtracting(previous).first {
            // Newly added wins: it is the row the user just clicked.
            focusedID = added
        } else if let current = focusedID, !selection.contains(current) {
            // The focused bead was deselected. Anything still selected will
            // do; nothing selected means nothing focused.
            focusedID = selection.first
        } else if selection.isEmpty {
            focusedID = nil
        }
        noteFocusChanged()
    }

    /// The selected ids in the order they appear on screen.
    ///
    /// A `Set` is unordered, so anything user-visible built from the selection
    /// — a copied list of ids, a count read aloud — has to impose an order or
    /// it changes between identical actions.
    public func orderedSelection(_ ids: Set<Issue.ID>? = nil) -> [Issue.ID] {
        let wanted = ids ?? selection
        guard !wanted.isEmpty else { return [] }
        var ordered = visibleIssues.map(\.id).filter { wanted.contains($0) }
        // Anything selected but not currently visible — the filter changed
        // under it — still belongs in the list, sorted so the result is
        // reproducible.
        let missing = wanted.subtracting(ordered).sorted()
        ordered.append(contentsOf: missing)
        return ordered
    }

    // MARK: - Loading

    /// Whether `path` would open, asked without loading it.
    ///
    /// Routed through ``OpenPanelGuard/engineProbe(_:)`` rather than calling
    /// the engine again here, so launch discovery, the Open panel and the
    /// loader all answer from one predicate. A probe that could not answer
    /// counts as "no".
    static func canOpen(_ path: String) -> Bool {
        OpenPanelGuard.engineProbe(path).canOpen
    }

    /// Opens whichever workspace launch should land on, or none.
    ///
    /// Candidates, in order: a path argument, `VBX_WORKSPACE`, the most
    /// recently opened workspaces, and finally the current directory.
    ///
    /// Each is *probed* rather than opened. Launched from the Dock or Finder a
    /// GUI app's current directory is `/`, which holds no beads, so attempting
    /// it set ``loadError`` and every launch opened onto "Could not open
    /// workspace" before the user had asked for anything. `loadError` means
    /// *you pointed at something and it did not work*; discovery pointing at
    /// nothing is not that. When no candidate probes openable this opens
    /// nothing and leaves `loadError` nil, and the "No workspace open" empty
    /// state — with its Choose Workspace… button — appears on its own.
    public func openInitialWorkspace() async {
        await openInitialWorkspace(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: FileManager.default.currentDirectoryPath,
            probe: Self.canOpen)
    }

    /// - Parameter probe: injected so tests can drive discovery without a
    ///   workspace on disk for every candidate.
    func openInitialWorkspace(
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        probe: (String) -> Bool
    ) async {
        // Flags are dropped: a Finder or Xcode launch adds its own, and none
        // of them name a workspace.
        let requested = [
            arguments.first { !$0.hasPrefix("-") },
            environment["VBX_WORKSPACE"],
        ].compactMap { $0 }

        // All the recents rather than only the newest: a list whose head has
        // been deleted should still return the user to where they were, and
        // `entries` has already dropped the paths that no longer exist.
        let candidates = requested + recents.entries.map(\.path) + [currentDirectory]

        if let openable = candidates.first(where: probe) {
            await open(path: openable)
            return
        }

        // Nothing opened — but a path the user named on the command line or in
        // the environment is still something they pointed at, so it is worth an
        // error rather than silence. Only when it exists: an argument that is
        // not a path at all is launch noise, not a request.
        if let named = requested.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            await open(path: named)
            return
        }

        loadError = nil
    }

    /// Opens the workspace a restored window was showing, or nothing.
    ///
    /// Same rule as discovery: the user did not choose this path *this* launch,
    /// so a workspace that has since moved leaves the window in the neutral
    /// empty state rather than reporting a failure nobody asked for.
    public func openRestoredWorkspace(path: String) async {
        await openRestoredWorkspace(path: path, probe: Self.canOpen)
    }

    func openRestoredWorkspace(path: String, probe: (String) -> Bool) async {
        guard probe(path) else {
            loadError = nil
            return
        }
        await open(path: path)
    }

    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder, a .beads directory, or a bead data file."
        panel.prompt = "Open"
        // Held for the panel's lifetime: `delegate` is unowned, and the guard
        // is also the probe cache, so it must not be collected mid-browse.
        let guardDelegate = OpenPanelGuard()
        panel.delegate = guardDelegate
        defer { panel.delegate = nil }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(path: url.path) }
    }

    public func open(path: String) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Captured before the swap: the resolved source is what identifies a
        // workspace, so this is what says whether the filters below belong to
        // the workspace being left or the one being opened.
        let previousSource = info?.source

        do {
            let info = try await engine.open(path: path, skipPhase2: skipPhase2)
            self.info = info
            // Before refreshAll, so the first render of the new workspace is
            // already unfiltered rather than briefly showing someone else's
            // filters — or nothing at all.
            if info.source != previousSource {
                resetWorkspaceFilters()
            }
            try await refreshAll()
            // Positions name beads, and the previous workspace's beads do not
            // exist in this one.
            resetNavigationHistory()
            // Recorded only once the open has succeeded: a path that failed to
            // load is not somewhere the user has been, and offering it again
            // in the menu would just reproduce the error.
            recents.record(path)
            // Loaded here rather than from the sidebar section that shows
            // them: that view renders before any workspace has, so its `.task`
            // ran while `isLoaded` was still false, returned early, and never
            // ran again. The recipes existed the whole time and the list was
            // always empty.
            await loadRecipes()
            startWatching()
            await refreshDirtyState()
            if !skipPhase2 { await computePhase2() }
        } catch {
            stopWatching()
            self.loadError = error.localizedDescription
            self.info = nil
            self.issues = []
            self.metrics = .empty
            self.actionable = []
            self.plan = .empty
            self.edges = []
        }
    }

    /// Re-reads the source. When the engine reports the data hash unchanged,
    /// nothing is republished — this is what makes watching cheap enough to
    /// leave on.
    @discardableResult
    public func reload(force: Bool = false) async -> Bool {
        guard isLoaded else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await engine.reload()
            info = fresh
            guard fresh.changed || force else { return false }

            try await refreshAll()
            // Recipes live in the workspace, so one can be added or removed by
            // an edit on disk — the same reason the beads themselves are
            // re-read here.
            await loadRecipes()
            if !skipPhase2 { await computePhase2() }
            // Every correlation attribution was computed against the old bead
            // set, so the report is stale. It is marked unloaded rather than
            // re-walked here: the walk is expensive and only matters if the
            // History view is actually open.
            historyLoaded = false
            lastReloadAt = Date()
            // Every write reloads, so this is where an edit made in vbx becomes
            // visible as uncommitted — and where an external `br` run does too.
            await refreshDirtyState()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    // MARK: - Watching

    /// Starts live reload for the currently open workspace.
    public func startWatching() {
        guard let source = info?.source, !isWatching else { return }
        watcher.start(watching: source) { [weak self] in
            Task { @MainActor in
                await self?.reload()
            }
        }
        // A commit does not touch the export, so the watch above cannot see
        // one. This does — and only the dirty state is recomputed, because
        // nothing about the beads themselves has changed.
        if let head = gitHeadPath {
            gitWatcher.start(watching: head) { [weak self] in
                Task { @MainActor in
                    await self?.refreshDirtyState()
                }
            }
        }
        isWatching = watcher.isWatching
    }

    public func stopWatching() {
        watcher.stop()
        gitWatcher.stop()
        isWatching = false
    }

    /// `<workspace>/.git/HEAD`, when the workspace is in a git repository.
    ///
    /// Watching the file rather than the directory: `FileWatchService` watches
    /// a path's *parent*, so this ends up watching `.git`, which is what also
    /// catches the index moving.
    public var gitHeadPath: String? {
        guard let workspace = workspaceDirectory else { return nil }
        let head = URL(fileURLWithPath: workspace)
            .appendingPathComponent(".git")
            .appendingPathComponent("HEAD")
        return FileManager.default.fileExists(atPath: head.path) ? head.path : nil
    }

    private func refreshAll() async throws {
        issues = try await engine.issues()
        metrics = try await engine.metrics()
        actionable = try await engine.actionableIDs()
        plan = try await engine.executionPlan()
        edges = try await engine.graphEdges()
        // Label analytics are advisory, so a failure here must not block the
        // load — a workspace with no labels at all is perfectly valid.
        labelAnalysis = (try? await engine.labelHealth()) ?? .empty
        labelFlow = (try? await engine.labelFlow()) ?? .empty
        labelAttention = (try? await engine.labelAttention()) ?? .empty
        repos = (try? await engine.repos()) ?? .empty
        // Spotlight is refreshed on every load so a deleted bead stops being
        // findable; the indexer replaces rather than merges for that reason.
        await updateSpotlightIndex()
        // Alerts are cheap once the analysis exists, and they are the one
        // thing a user wants to see without asking.
        await refreshAlerts()
        // Triage depends on Phase-2 scores; it is refreshed again once they land.
        triage = (try? await engine.triage()) ?? .empty
        rebuildUnblocksCache()
        // Drop ids the reload removed, and fall back to the first row when
        // that empties the selection — an empty inspector after a reload reads
        // as a broken app rather than as a changed bead set.
        let surviving = selection.filter { id in issues.contains { $0.id == id } }
        if surviving.isEmpty {
            selection = visibleIssues.first.map { [$0.id] } ?? []
        } else if surviving != selection {
            selection = surviving
        }
    }

    /// Waits for the expensive metrics off the main actor, then republishes.
    ///
    /// Gating on `hasPhase2Values` rather than `phase2Ready` matters: a session
    /// opened with metrics skipped reports ready with nothing in it, and
    /// waiting again would return the same emptiness forever.
    public func computePhase2() async {
        guard isLoaded, !metrics.hasPhase2Values, !phase2InFlight else { return }
        phase2InFlight = true
        defer { phase2InFlight = false }
        do {
            triageNeedsRefresh = true
            metrics =
                metrics.phase2Ready
                ? try await engine.computeFullMetrics()
                : try await engine.waitForPhase2()
            actionable = try await engine.actionableIDs()
            // Recommendations are scored from PageRank and betweenness, so
            // they are only meaningful once Phase 2 has landed.
            if triageNeedsRefresh {
                triage = (try? await engine.triage()) ?? triage
                triageNeedsRefresh = false
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func close() async {
        stopWatching()
        await engine.close()
    }

    // MARK: - Search

    public func loadSearchPresets() async {
        guard isLoaded, searchPresets.presets.isEmpty else { return }
        searchPresets = (try? await engine.searchPresets()) ?? .empty
    }

    /// Runs the engine-backed search for the current query text.
    ///
    /// Only used in hybrid mode. The plain path stays on `IssueQuery`'s fuzzy
    /// ranking, which is synchronous and needs no index — searching should not
    /// wait on a round trip while someone is still typing.
    public func runEngineSearch() async {
        let text = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, searchMode == .hybrid, !text.isEmpty else {
            searchResults = .empty
            return
        }
        guard !searchInFlight else { return }

        searchInFlight = true
        defer { searchInFlight = false }
        searchResults =
            (try? await engine.search(
                text, mode: searchMode, limit: 50,
                preset: searchWeights == nil ? searchPreset : nil,
                weights: searchWeights)) ?? .empty
    }

    /// True when the list should show engine-ranked results.
    public var isUsingEngineSearch: Bool {
        searchMode == .hybrid && !query.searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty && !searchResults.isEmpty
    }

    // MARK: - Sprints

    /// Loads the sprint list, the selected sprint's burndown and the capacity
    /// simulation.
    public func loadSprints() async {
        guard isLoaded else { return }
        sprintError = nil

        sprints = (try? await engine.sprints()) ?? .empty
        // No sprint file at all is a normal state for a workspace, not an
        // error, so it is reported by the empty list rather than a message.
        guard !sprints.sprints.isEmpty else {
            burndown = .empty
            await loadCapacity()
            return
        }

        do {
            let target = selectedSprintID.isEmpty ? "current" : selectedSprintID
            burndown = try await engine.burndown(sprintID: target)
        } catch {
            // The commonest case by far: sprints exist but none spans today.
            burndown = .empty
            sprintError = error.localizedDescription
        }
        await loadCapacity()
    }

    /// Re-runs the capacity simulation at the current agent count.
    public func loadCapacity() async {
        guard isLoaded else { return }
        capacity = (try? await engine.capacity(agents: capacityAgents)) ?? .empty
    }

    // MARK: - Recipes

    public func loadRecipes() async {
        guard isLoaded else { return }
        recipes = (try? await engine.recipes()) ?? .empty
    }

    /// Applies a recipe: filter, sort and view, together.
    ///
    /// The selection and its order come from the engine, so a recipe means the
    /// same thing here as it does to `bv --recipe`.
    public func applyRecipe(named name: String) async {
        guard isLoaded else { return }
        do {
            let applied = try await engine.applyRecipe(named: name)
            activeRecipe = applied.recipe
            recipeIDs = applied.issueIDs
            recipeTruncated = applied.truncated
            // A recipe that asks for the graph gets it; the rest leave the
            // current surface alone rather than yanking the user elsewhere.
            if applied.recipe.view.impliedSurface == "graph" { surface = .graph }
            // A recipe changes what is on screen, so a selection pointing
            // outside its results would leave the inspector showing a bead the
            // list no longer contains.
            let surviving = selection.intersection(applied.issueIDs)
            if surviving.isEmpty {
                selection = applied.issueIDs.first.map { [$0] } ?? []
            } else {
                selection = surviving
            }
        } catch {
            loadError = error.localizedDescription
            clearRecipe()
        }
    }

    /// Drops every filter that named something in the previous workspace.
    ///
    /// Labels, assignees, repository names and a recipe's ids are all
    /// workspace-specific strings, so carried across a switch they typically
    /// match nothing: the list comes up empty with no visible cause, and an
    /// empty table reads as "this workspace has no beads" rather than "you are
    /// still looking through the last workspace's filter".
    ///
    /// The same rule already governs the navigation history and the selection
    /// in ``open(path:)`` — a label is workspace-specific in exactly the way a
    /// recorded position or a selected id is.
    ///
    /// ``surface`` is deliberately left alone. Which view you are on is not a
    /// filter, it names nothing inside the workspace, and carrying it across is
    /// what someone comparing two workspaces in the same view would want.
    func resetWorkspaceFilters() {
        query = IssueQuery()
        repoFilter = []
        clearRecipe()
        alertSeverityFilter = nil
        alertTypeFilter = nil
    }

    /// Whether beads can be edited right now.
    ///
    /// Two reasons they cannot. `br` may not be installed, which is a normal
    /// state — vbx stays a viewer and the affordance says why. And while time
    /// travelling the list shows a *past* revision, so an edit would write
    /// today's data from a view of last week's; refusing is the honest answer.
    public var canEditBeads: Bool {
        writer.isAvailable && isLoaded && !isTimeTravelling
    }

    /// Why editing is unavailable, for the disabled control to explain itself.
    public var editingUnavailableReason: String? {
        if !writer.isAvailable {
            return "Install br to edit beads from vbx."
        }
        if isTimeTravelling {
            return "Editing is unavailable while viewing a past revision."
        }
        return nil
    }

    // MARK: - Uncommitted beads

    /// Which beads differ from the last commit.
    ///
    /// ``BeadDirtyState/unknown`` until it has been computed, and again
    /// whenever there is nothing to compare against — a workspace with no git
    /// repository, or one with no commits yet. That is not the same as clean,
    /// and the UI must not render it as such.
    @Published public private(set) var dirtyBeads: BeadDirtyState = .unknown

    /// Recomputes the dirty state against `HEAD`.
    ///
    /// The committed bead set comes from the engine's `snapshot_at`, which
    /// reads the git object store directly — the same path time travel uses,
    /// and the reason this works in a sandbox where shelling out to `git` would
    /// not (ADR-006).
    ///
    /// A failure means there is nothing to compare against rather than that
    /// something went wrong: an unopened workspace, a directory that is not a
    /// repository, a repository with no commits. None of those is an error
    /// worth showing, and all of them are "unknown" rather than "clean".
    public func refreshDirtyState() async {
        guard isLoaded, !isTimeTravelling else {
            dirtyBeads = .unknown
            return
        }
        do {
            let head = try await engine.snapshot(at: "HEAD")
            dirtyBeads = BeadDirtyState.compare(working: issues, committed: head.issues)
        } catch {
            dirtyBeads = .unknown
        }
    }

    /// Whether this bead has changes that are not committed.
    public func isDirty(_ id: Issue.ID) -> Bool { dirtyBeads.isDirty(id) }

    /// Sets a bead's priority, through `br`.
    ///
    /// Reloads afterwards rather than patching the in-memory bead: `br` owns
    /// the database and the export, so the file on disk is what is true and
    /// the copy in memory is stale the moment the command returns.
    @discardableResult
    public func setPriority(_ priority: Int, for id: Issue.ID) async -> Bool {
        guard canEditBeads, let workspace = workspaceDirectory else { return false }
        do {
            try await writer.setPriority(priority, for: id, in: workspace)
            await reload(force: true)
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// Sets the priority of every bead in `ids`, through `br`.
    ///
    /// Sequential rather than concurrent: `br` owns the database, and several
    /// processes writing it at once is how a sqlite lock error becomes a
    /// half-applied change. One reload at the end rather than one per bead,
    /// because reloading is the expensive part and the intermediate states are
    /// not worth rendering.
    ///
    /// Returns the ids it could not write. An empty set is complete success;
    /// a partial failure still reloads, because the beads that did change are
    /// on disk and the list must not keep showing their old values.
    @discardableResult
    public func setPriority(_ priority: Int, for ids: Set<Issue.ID>) async -> Set<Issue.ID> {
        guard canEditBeads, let workspace = workspaceDirectory else { return ids }
        var failed: Set<Issue.ID> = []
        var lastError: String?
        for id in ids.sorted() {
            do {
                try await writer.setPriority(priority, for: id, in: workspace)
            } catch {
                failed.insert(id)
                lastError = error.localizedDescription
            }
        }
        await reload(force: true)
        if let lastError {
            loadError = failed.count == 1
                ? lastError
                : "\(failed.count) of \(ids.count) beads could not be updated: \(lastError)"
        }
        return failed
    }

    /// Renames a bead, through `br`.
    ///
    /// An unchanged or empty title is refused rather than written. Empty
    /// because a bead with no title is unusable in every list that shows one,
    /// and unchanged because committing a field editor the user only clicked
    /// into should not produce a write, a reload and a history entry.
    @discardableResult
    public func setTitle(_ title: String, for id: Issue.ID) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditBeads, let workspace = workspaceDirectory else { return false }
        guard !trimmed.isEmpty else { return false }
        guard trimmed != issues.first(where: { $0.id == id })?.title else { return false }
        do {
            try await writer.setTitle(trimmed, for: id, in: workspace)
            await reload(force: true)
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// The directory `br` should run in — the workspace, not the data file.
    var workspaceDirectory: String? {
        guard let source = info?.source else { return nil }
        // `<workspace>/.beads/issues.jsonl` → `<workspace>`.
        return URL(fileURLWithPath: source)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    /// Adds a label to the filter, or removes it if it is already there.
    ///
    /// One gesture in both directions, so the pill reads as a toggle rather
    /// than two different commands depending on state.
    ///
    /// An active recipe is cleared. A recipe owns the filter and the sort
    /// wholesale — `applyRecipe(named:)` writes `query` outright — so a filter
    /// the user has since edited by hand is no longer the recipe's. Leaving it
    /// active would keep the sidebar claiming a recipe that no longer
    /// describes what is on screen.
    public func toggleLabelFilter(_ label: String) {
        if query.labels.contains(label) {
            query.labels.remove(label)
        } else {
            query.labels.insert(label)
        }
        if activeRecipe != nil { clearRecipe() }
    }

    /// Returns to the ordinary filter and sort.
    public func clearRecipe() {
        activeRecipe = nil
        recipeIDs = nil
        recipeTruncated = false
    }

    public func saveRecipe(_ recipe: Recipe) async {
        do {
            try await engine.saveRecipe(recipe)
            await loadRecipes()
            // Re-apply so the edit is visible immediately rather than after
            // the next click.
            if activeRecipe?.name == recipe.name {
                await applyRecipe(named: recipe.name)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func deleteRecipe(named name: String) async {
        do {
            try await engine.deleteRecipe(named: name)
            if activeRecipe?.name == name { clearRecipe() }
            await loadRecipes()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Alerts

    /// Re-runs the drift check with the current filters.
    public func refreshAlerts() async {
        guard isLoaded else { return }
        let previous = Set(alerts.alerts.filter { $0.severity == .critical }.map(\.id))

        alerts =
            (try? await engine.alerts(
                severity: alertSeverityFilter,
                type: alertTypeFilter,
                label: alertLabelFilter)) ?? .empty
        baseline = (try? await engine.baselineInfo()) ?? .empty

        // Only alerts that were not there a moment ago are announced. Without
        // this every reload would re-notify about the same standing problem,
        // and the notifications would quickly be ignored.
        let fresh = alerts.alerts.filter { $0.severity == .critical && !previous.contains($0.id) }
        if notifyOnCriticalAlerts, !fresh.isEmpty {
            await notifier.deliver(fresh)
        }
    }

    /// Records the current graph as the point drift is measured from.
    public func saveBaseline(description: String) async {
        guard isLoaded else { return }
        do {
            baseline = try await engine.saveBaseline(description: description)
            // A new baseline changes every delta, so the alerts are recomputed
            // rather than left describing the previous one.
            await refreshAlerts()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Time travel

    /// True when a revision is selected and the list is showing diff badges.
    public var isTimeTravelling: Bool { !timeTravel.resolvedRevision.isEmpty }

    /// Loads the revisions the scrubber can jump to.
    public func loadRevisions() async {
        guard isLoaded, revisions.revisions.isEmpty else { return }
        revisions = (try? await engine.revisions()) ?? .empty
    }

    /// Compares the current bead set against `revision`.
    ///
    /// Any expression git accepts works; what gets displayed afterwards is the
    /// *resolved* commit, because `HEAD~3` names a different commit tomorrow.
    public func travel(to revision: String) async {
        guard isLoaded, !timeTravelLoading else { return }
        timeTravelLoading = true
        defer { timeTravelLoading = false }

        do {
            timeTravel = try await engine.diff(since: revision)
            let snapshot = try await engine.snapshot(at: revision)
            pastIssues = Dictionary(
                snapshot.issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            historyError = error.localizedDescription
            returnToNow()
        }
    }

    /// Leaves time travel.
    public func returnToNow() {
        timeTravel = .empty
        pastIssues = [:]
    }

    /// The badge a bead earned between the chosen revision and now.
    public func badge(for id: Issue.ID) -> DiffBadge? {
        timeTravel.badges[id]
    }

    /// The bead as it was at the chosen revision, if it existed then.
    public func pastIssue(_ id: Issue.ID) -> Issue? {
        pastIssues[id]
    }

    // MARK: - Correlation

    /// Loads the git correlation report, once.
    ///
    /// Idempotent, so a view can call it from `.task` on every appearance
    /// without paying for a second walk. Pass `refresh` to force one.
    public func loadHistory(refresh: Bool = false) async {
        guard isLoaded, !historyLoading else { return }
        guard refresh || !historyLoaded else { return }

        historyLoading = true
        historyError = nil
        defer { historyLoading = false }

        do {
            history = try await engine.history(refresh: refresh)
            // These read the same cached report, so they are cheap once the
            // walk is done.
            orphans = (try? await engine.orphanCommits()) ?? .empty
            hotspots = (try? await engine.fileHotspots()) ?? .empty
            feedback = (try? await engine.correlationFeedback()) ?? .empty
            historyLoaded = true
        } catch {
            // A workspace outside a git repository is a normal state, not a
            // failure of the app — the History view says so rather than the
            // whole window showing an error.
            historyError = error.localizedDescription
            historyLoaded = false
            history = .empty
            orphans = .empty
            hotspots = .empty
        }
    }

    /// The commits linked to one bead, newest first.
    public func commits(for id: Issue.ID) -> [CorrelatedCommit] {
        history.histories[id]?.commits ?? []
    }

    /// One bead's causal chain, fetched on demand.
    public func causality(for id: Issue.ID) async -> CausalityResult? {
        try? await engine.causality(id)
    }

    public func relatedWork(for id: Issue.ID) async -> RelatedWork? {
        try? await engine.relatedWork(id)
    }

    public func beads(touching path: String) async -> FileBeadLookup? {
        try? await engine.beads(touching: path)
    }

    public func fileRelations(for path: String) async -> CoChangeResult? {
        try? await engine.fileRelations(path)
    }

    public func patch(sha: String, path: String? = nil) async -> CommitPatch? {
        try? await engine.commitPatch(sha: sha, path: path)
    }

    /// Records a verdict on one commit-to-bead link and republishes the report.
    ///
    /// The report is re-read rather than patched locally: rejecting a link
    /// also rebuilds the commit index and the orphan list, and reproducing
    /// that here would be a second implementation of the same rule.
    public func recordCorrelation(
        sha: String, beadID: String, confirmed: Bool, reason: String = ""
    ) async {
        do {
            if confirmed {
                try await engine.confirmCorrelation(sha: sha, beadID: beadID, reason: reason)
            } else {
                try await engine.rejectCorrelation(sha: sha, beadID: beadID, reason: reason)
            }
            history = try await engine.history()
            orphans = (try? await engine.orphanCommits()) ?? orphans
            feedback = (try? await engine.correlationFeedback()) ?? feedback
        } catch {
            historyError = error.localizedDescription
        }
    }

    // MARK: - Export

    /// Renders the Markdown report and asks the user where to save it.
    ///
    /// The engine returns the content and this writes it, rather than letting
    /// the engine write directly, so the save panel's grant is what authorises
    /// the write — which is what keeps it working under the App Sandbox.
    public func exportMarkdown() async {
        guard let info else { return }
        do {
            let report = try await engine.exportMarkdown(title: "\(info.displayName) — Bead Report")

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(info.displayName)-beads.md"
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.message = "Save the Markdown report"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            try report.markdown.write(to: url, atomically: true, encoding: .utf8)
            lastExportPath = url.path
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Static site export

    /// Asks where to put the bundle, then builds it.
    ///
    /// The directory comes from an open panel because that grant is what
    /// authorises writing outside the app's container.
    public func chooseBundleDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder for the static site bundle."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    public func buildSite(
        into directory: URL, title: String,
        interactiveGraph: Bool, githubWorkflow: Bool
    ) async {
        guard isLoaded, !siteBusy else { return }
        siteBusy = true
        siteError = nil
        defer { siteBusy = false }

        do {
            siteBundle = try await engine.exportSite(
                outputDir: directory.path, title: title,
                interactiveGraph: interactiveGraph, githubWorkflow: githubWorkflow)
            // A new bundle invalidates any previous deployment result.
            siteDeployment = .empty
        } catch {
            siteError = error.localizedDescription
            siteBundle = .empty
        }
    }

    /// Starts the local preview server for the built bundle.
    public func previewSite() async {
        guard siteBundle.isBuilt, !siteBusy else { return }
        siteBusy = true
        defer { siteBusy = false }
        do {
            sitePreview = try await engine.previewSite(bundlePath: siteBundle.outputDir)
        } catch {
            siteError = error.localizedDescription
            sitePreview = .empty
        }
    }

    /// Publishes the bundle to GitHub Pages using the stored token.
    public func deploySite(repo: String, isPrivate: Bool) async {
        guard siteBundle.isBuilt, !siteBusy else { return }
        guard let token = Keychain.read(.githubToken) else {
            siteError = "No GitHub token is stored. Add one in Settings first."
            return
        }

        siteBusy = true
        siteError = nil
        defer { siteBusy = false }

        do {
            siteDeployment = try await engine.deployToGitHub(
                bundlePath: siteBundle.outputDir, repo: repo,
                token: token, isPrivate: isPrivate)
        } catch {
            siteError = error.localizedDescription
            siteDeployment = .empty
        }
    }

    /// What to run for a Cloudflare deployment, which needs `wrangler`.
    public func cloudflareInstructions(project: String) async -> DeployInstructions {
        guard siteBundle.isBuilt else { return .empty }
        return (try? await engine.cloudflareInstructions(
            bundlePath: siteBundle.outputDir, project: project)) ?? .empty
    }

    /// Clears the wizard's state so a second run starts fresh.
    public func resetSiteExport() {
        siteBundle = .empty
        sitePreview = .empty
        siteDeployment = .empty
        siteError = nil
    }

    // MARK: - Derived data

    /// Ids that closing `id` would make actionable.
    ///
    /// Answers from the cache when the plan or triage already reported it,
    /// falling back to the engine for beads neither covers.
    public func unblocks(_ id: String) async -> [String] {
        if let cached = unblocksCache[id] { return cached }
        let fetched = (try? await engine.unblocks(id)) ?? []
        unblocksCache[id] = fetched
        return fetched
    }

    /// Synchronous lookup for views that must render without awaiting.
    /// Returns nil when the value is not yet known, which the UI shows as
    /// "—" rather than as a misleading zero.
    public func knownUnblocks(_ id: String) -> [String]? { unblocksCache[id] }

    private func rebuildUnblocksCache() {
        var cache: [String: [String]] = [:]
        for track in plan.tracks {
            for item in track.items { cache[item.id] = item.unblocks }
        }
        for rec in triage.recommendations where cache[rec.id] == nil {
            cache[rec.id] = rec.unblocksIDs
        }
        for win in triage.quickWins where cache[win.id] == nil {
            cache[win.id] = win.unblocksIDs
        }
        for blocker in triage.blockersToClear where cache[blocker.id] == nil {
            cache[blocker.id] = blocker.unblocksIDs
        }
        unblocksCache = cache
    }

    public var labelCounts: [(label: String, count: Int)] { issues.labelCounts }

    /// Dependencies of `issue` paired with the issue they point at.
    public func blockers(of issue: Issue) -> [(Dependency, Issue?)] {
        let byID = issuesByID
        return issue.dependencies.map { ($0, byID[$0.dependsOnID]) }
    }

    /// Issues that list `issue` as a dependency.
    public func dependents(of issue: Issue) -> [Issue] {
        issues.filter { candidate in
            candidate.dependencies.contains { $0.dependsOnID == issue.id }
        }
    }

    /// A one-line health report used by the headless self-check and the
    /// status bar, so both describe the workspace the same way.
    public func summaryLine() -> String {
        guard let info else { return "no workspace" }
        return "\(info.displayName): \(issues.count) beads, \(actionable.count) ready, "
            + "\(metrics.nodeCount) nodes / \(metrics.edgeCount) edges, "
            + "phase2=\(metrics.phase2Ready)"
    }
}
