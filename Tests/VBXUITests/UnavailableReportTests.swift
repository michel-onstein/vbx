@testable import VBXAppCore
import VBXCore
import VBXEngine
import SwiftUI
import Testing

@testable import VBXUI

/// Every report the store reads from the engine and shows: a failure is
/// published as unavailable, never as an empty report (vbx-lh0, vbx-twy).
///
/// Each read used to be `(try? …) ?? .empty`, so a failed engine call drew
/// "No alerts", "No labels", "Nothing is actionable right now" or a zero —
/// claims about the workspace that nothing had checked.
@MainActor
@Suite("Unavailable reports")
struct UnavailableReportTests {

    /// The failure injected for `report`, as the engine raises one.
    static func failure(_ report: EngineReport) -> EngineError {
        .callFailed(method: report.rawValue, message: "injected failure")
    }

    /// A bead outside the plan and triage, so its unblocks are not cached and
    /// the read reaches the engine.
    static let uncachedBead = "vbx-1"

    /// Asks for `report` the way the app does, and says whether the store is
    /// now holding nothing for it.
    @discardableResult
    static func load(_ report: EngineReport, into store: ProjectStore) async -> Bool {
        switch report {
        case .orphans:
            await store.loadHistory(refresh: true)
            return store.orphans.candidates.isEmpty && store.orphans.stats.totalCommits == 0
        case .hotspots:
            await store.loadHistory(refresh: true)
            return store.hotspots.hotspots.isEmpty
        case .correlationFeedback:
            await store.loadHistory(refresh: true)
            return store.feedback.stats.totalFeedback == 0
        case .labelHealth:
            await store.reload(force: true)
            return store.labelAnalysis.labels.isEmpty
        case .labelFlow:
            await store.reload(force: true)
            return store.labelFlow.labels.isEmpty
        case .labelAttention:
            await store.reload(force: true)
            return store.labelAttention.labels.isEmpty
        case .repos:
            await store.reload(force: true)
            return store.repos.repos.isEmpty
        case .triage:
            await store.reload(force: true)
            return store.triage.recommendations.isEmpty && store.triage.quickWins.isEmpty
        case .triageFeedback:
            await store.reload(force: true)
            return store.triageFeedbackState == nil
        case .alerts:
            await store.refreshAlerts()
            return store.alerts.alerts.isEmpty
        case .baseline:
            await store.refreshAlerts()
            return !store.baseline.exists
        case .searchPresets:
            // The presets are offered only while a hybrid search is typed.
            store.query.searchText = "issue"
            store.searchMode = .hybrid
            await store.loadSearchPresets()
            return store.searchPresets.presets.isEmpty
        case .search:
            store.query.searchText = "issue"
            store.searchMode = .hybrid
            await store.runEngineSearch()
            return store.searchResults.results.isEmpty
        case .sprints:
            await store.loadSprints()
            return store.sprints.sprints.isEmpty
        case .capacity:
            await store.loadCapacity()
            return store.capacity.openIssueCount == 0
        case .recipes:
            await store.loadRecipes()
            return store.recipes.recipes.isEmpty
        case .revisions:
            await store.loadRevisions()
            return store.revisions.revisions.isEmpty
        case .causality:
            return await store.causality(for: "vbx-4") == nil
        case .fileLookup:
            return await store.beads(touching: "Sources/IssueList.swift") == nil
        case .patch:
            let sha = store.commits(for: "vbx-4").first?.sha ?? "HEAD"
            return await store.patch(sha: sha) == nil
        case .unblocks:
            // Nothing cached either: an empty list would be "unblocks 0".
            return await store.unblocks(uncachedBead) == nil
                && store.knownUnblocks(uncachedBead) == nil
        case .cloudflareInstructions:
            if !store.siteBundle.isBuilt {
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("vbx-site-\(UUID().uuidString)")
                await store.buildSite(
                    into: directory, title: "Demo", interactiveGraph: false,
                    githubWorkflow: false)
            }
            return await store.cloudflareInstructions(project: "demo").command.isEmpty
        }
    }

    @Test("An engine failure is published as unavailable, and a retry clears it",
          arguments: EngineReport.allCases)
    func failureIsUnavailable(_ report: EngineReport) async throws {
        let (store, directory) = try await Fixture.historyStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        if report.isHistory { await store.loadHistory() }

        store.injectedFailures[report] = Self.failure(report)
        let holdsNothing = await Self.load(report, into: store)

        #expect(
            store.unavailableReason(report) == Self.failure(report).localizedDescription,
            "\(store.unavailable)")
        #expect(holdsNothing, "a failed \(report) left a stale or partial report behind")
        // Only the one report is unavailable: no other read failed with it,
        // and the history it was read beside is still loaded.
        #expect(Set(store.unavailable.keys) == [report], "\(store.unavailable)")
        if report.isHistory { #expect(store.historyLoaded) }

        store.injectedFailures = [:]
        await Self.load(report, into: store)
        #expect(store.unavailableReason(report) == nil, "\(store.unavailable)")
        await store.close()
    }

    @Test("A healthy workspace has no unavailable report")
    func healthyWorkspace() async throws {
        // The normal empty states — no sprint file, no baseline, no feedback,
        // one repository — are answered by the engine as empty reports, and
        // must not be mistaken for failures now that failures are shown.
        let (store, directory) = try await Fixture.historyStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.loadHistory()
        for report in EngineReport.allCases {
            await Self.load(report, into: store)
        }
        #expect(store.unavailable.isEmpty, "\(store.unavailable)")
        await store.close()
    }

    @Test("A workspace outside git has no unavailable report")
    func workspaceOutsideGit() async throws {
        // No repository is a normal state too: History says so once, and the
        // revisions menu is empty rather than failed.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for report in EngineReport.allCases where !report.isHistory {
            await Self.load(report, into: store)
        }
        #expect(store.unavailable.isEmpty, "\(store.unavailable)")
        await store.close()
    }

    @Test("Opening another workspace forgets the failures of the last")
    func openForgetsFailures() async throws {
        let (store, directory) = try await Fixture.historyStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.injectedFailures[.alerts] = Self.failure(.alerts)
        await store.refreshAlerts()
        #expect(store.unavailableReason(.alerts) != nil)

        store.injectedFailures = [:]
        await store.open(path: Fixture.path)
        #expect(store.unavailable.isEmpty, "\(store.unavailable)")
        await store.close()
    }

    // MARK: - Snapshots

    /// The reports with a pane, panel, bar or section to draw. Not here: the
    /// revisions (a menu, which a snapshot does not open), unblocks (one glyph
    /// in the inspector, where the store test asserts nothing is cached) and
    /// the Cloudflare instructions (a wizard step behind its own state).
    static let drawn: [EngineReport] = [
        .orphans, .hotspots, .correlationFeedback, .labelHealth, .labelFlow,
        .labelAttention, .repos, .triage, .triageFeedback, .alerts, .baseline,
        .searchPresets, .search, .sprints, .capacity, .recipes, .causality,
        .fileLookup,
    ]

    /// The view that shows `report`, its size, and the region it draws in.
    static func surface(
        for report: EngineReport
    ) -> (view: AnyView, size: CGSize, region: CGRect) {
        let wide = CGSize(width: 900, height: 600)
        let whole = CGRect(origin: .zero, size: wide)
        // Below the History header, where its tabs draw.
        let historyBody = CGRect(x: 0, y: 140, width: 900, height: 460)
        switch report {
        case .orphans:
            return (AnyView(HistoryView(tab: .orphans)), wide, historyBody)
        case .hotspots:
            return (AnyView(HistoryView(tab: .hotspots)), wide, historyBody)
        case .correlationFeedback:
            // The header's counts, where "reviewed" sits.
            return (
                AnyView(HistoryView(tab: .commits)), wide,
                CGRect(x: 0, y: 30, width: 700, height: 40))
        case .causality:
            // Below the timeline, where the causal chain draws.
            return (
                AnyView(HistoryView(tab: .timeline)), wide,
                CGRect(x: 0, y: 340, width: 900, height: 260))
        case .fileLookup:
            return (AnyView(HistoryView(tab: .files)), wide, historyBody)
        case .labelHealth:
            return (AnyView(LabelsView()), wide, whole)
        case .labelFlow:
            return (AnyView(FlowMatrixView()), wide, whole)
        case .labelAttention:
            return (AnyView(AttentionView()), wide, whole)
        case .alerts:
            // Below the header and its filters, where the list draws.
            return (AnyView(AlertsView()), wide, CGRect(x: 0, y: 120, width: 900, height: 480))
        case .baseline:
            return (AnyView(AlertsView()), wide, CGRect(x: 0, y: 30, width: 900, height: 60))
        case .repos:
            let size = CGSize(width: 260, height: 260)
            return (
                AnyView(List { SidebarReposSection() }.listStyle(.sidebar)), size,
                CGRect(origin: .zero, size: size))
        case .recipes:
            let size = CGSize(width: 260, height: 400)
            return (
                AnyView(List { SidebarRecipesSection() }.listStyle(.sidebar)), size,
                CGRect(origin: .zero, size: size))
        case .triage:
            let size = CGSize(width: 520, height: 320)
            return (AnyView(RecommendationsPanel()), size, CGRect(origin: .zero, size: size))
        case .triageFeedback:
            let size = CGSize(width: 520, height: 80)
            return (
                AnyView(TriageFeedbackLine().padding(8)), size, CGRect(origin: .zero, size: size))
        case .searchPresets, .search:
            let size = CGSize(width: 900, height: 40)
            return (AnyView(SearchScopeBar()), size, CGRect(origin: .zero, size: size))
        case .sprints, .capacity:
            let size = CGSize(width: 900, height: 800)
            return (AnyView(SprintView()), size, CGRect(origin: .zero, size: size))
        case .revisions, .unblocks, .patch, .cloudflareInstructions:
            preconditionFailure("\(report) is not drawn by this test")
        }
    }

    @Test("A failed report draws unavailable, not empty", arguments: drawn)
    func unavailableIsNotEmpty(_ report: EngineReport) async throws {
        let (store, directory) = try await Fixture.historyStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.loadHistory()
        if report == .causality { _ = store.select(id: "vbx-4") }

        store.injectedFailures[report] = Self.failure(report)
        await Self.load(report, into: store)
        #expect(store.unavailableReason(report) != nil)

        let (view, size, region) = Self.surface(for: report)
        let failed = try Snapshot.render(
            view.environmentObject(store), name: "unavailable-\(report.rawValue)", size: size)

        // The same failure swallowed, as every call site did before vbx-twy:
        // an empty report and nothing on record — what the panel drew then.
        // Swallowed rather than merely cleared, because a view's `.task`
        // re-reads during the render and would record it again.
        store.swallowsInjectedFailures = true
        store.unavailable[report] = nil
        let empty = try Snapshot.render(
            view.environmentObject(store), name: "unavailable-\(report.rawValue)-as-empty",
            size: size)
        #expect(store.unavailableReason(report) == nil)

        // Something is drawn where the report goes...
        #expect(failed.inkCoverage(in: region) > 0.002, "\(report): nothing drawn")
        // ...and it is not what the empty report draws. Compared pixel for
        // pixel: "No labels" and "Label health unavailable" have the same ink
        // coverage to four places, being the same shape of thing.
        let difference = failed.difference(from: empty, in: region)
        #expect(difference > 0.002, "\(report): unavailable and empty differ by \(difference)")
        await store.close()
    }

    @Test("A failed diff opens a sheet saying so, not an empty diff")
    func patchUnavailable() throws {
        let store = ProjectStore()
        let failed = try Snapshot.render(
            PatchSheet(
                item: .unavailable(sha: "abc1234", path: nil, reason: "injected failure"),
                done: {}, retry: {}
            ).environmentObject(store),
            name: "unavailable-patch", size: CGSize(width: 760, height: 560))
        let empty = try Snapshot.render(
            PatchSheet(item: .loaded(CommitPatch(sha: "abc1234")), done: {}, retry: {})
                .environmentObject(store),
            name: "unavailable-patch-as-empty", size: CGSize(width: 760, height: 560))
        // Below the sheet's header.
        let body = CGRect(x: 0, y: 50, width: 760, height: 510)
        #expect(
            failed.inkCoverage(in: body) > 3 * empty.inkCoverage(in: body),
            "unavailable \(failed.inkCoverage(in: body)), empty \(empty.inkCoverage(in: body))")
    }
}
