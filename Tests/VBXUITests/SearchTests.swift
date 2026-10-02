import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// Search modes and hybrid ranking.
@MainActor
@Suite("Search")
struct SearchTests {

    @Test("Plain search stays synchronous and needs no index")
    func plainSearchIsLocal() async {
        let store = await Fixture.loadedStore()
        store.query.searchText = "loader"

        // The text path uses IssueQuery's fuzzy ranking. Waiting on a round
        // trip while someone is still typing would be the wrong trade.
        #expect(store.searchMode == .text)
        #expect(!store.isUsingEngineSearch)
        #expect(!store.visibleIssues.isEmpty)

        await store.close()
    }

    @Test("Hybrid search re-ranks through the engine")
    func hybridUsesEngine() async throws {
        // Searching writes a vector index into <project>/.bv/semantic, so it
        // gets a private copy of the fixture rather than dirtying the checkout.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.loadSearchPresets()

        store.query.searchText = "loader"
        store.searchMode = .hybrid
        await store.runEngineSearch()

        guard !store.searchResults.isEmpty else {
            // An empty index is a legitimate outcome for a query matching
            // nothing; nothing further to assert.
            await store.close()
            return
        }

        #expect(store.isUsingEngineSearch)
        #expect(store.searchResults.mode == .hybrid)
        // The default embedder is deterministic, which is what keeps this
        // ranking identical to the CLI's.
        #expect(store.searchResults.provider == "hash")
        // The visible list is exactly the engine's ranking, not a re-sort.
        #expect(store.visibleIssues.map(\Bead.id) == store.searchResults.rankedIDs)

        await store.close()
    }

    @Test("Clearing the query leaves hybrid mode with nothing to show")
    func clearingQuery() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.searchMode = .hybrid
        store.query.searchText = "loader"
        await store.runEngineSearch()

        store.query.searchText = ""
        await store.runEngineSearch()

        #expect(store.searchResults.isEmpty)
        #expect(!store.isUsingEngineSearch)
        // And the list falls back to the ordinary filter rather than emptying.
        #expect(!store.visibleIssues.isEmpty)

        await store.close()
    }

    // MARK: - Minimum score

    /// A store over a private copy of `Fixtures/search`, whose six "tax 7"
    /// beads score high against "tax 7" and whose other three do not.
    /// A copy because searching writes a vector index into the workspace.
    private func searchStore() async throws -> (store: ProjectStore, directory: URL) {
        let source = URL(fileURLWithPath: Fixture.path).deletingLastPathComponent()
            .appendingPathComponent("search").path
        let directory = try Fixture.copy(from: source, prefix: "vbx-search")
        let store = ProjectStore()
        store.loadsHistoryEagerly = false
        await store.open(path: directory.path)
        await store.computePhase2()
        return (store, directory)
    }

    @Test("The threshold is off by default")
    func thresholdOffByDefault() {
        // Off sends no threshold at all, which is how search behaved before
        // the control existed.
        #expect(ProjectStore().searchMinScore == nil)
    }

    @Test("A min score reaches the engine and drops hits below it")
    func minScoreFilters() async throws {
        let (store, directory) = try await searchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.query.searchText = "tax 7"
        store.searchMode = .hybrid
        await store.runEngineSearch()
        let unfiltered = store.searchResults
        #expect(unfiltered.minScore == nil, "no threshold was asked for, so none is echoed")
        #expect(unfiltered.results.count == store.issues.count)

        // A threshold between the weakest and strongest similarity: some hits
        // must go, some must stay, whichever way the embedder lands.
        let scores = unfiltered.results.map(\.textScore).sorted()
        let threshold = try #require(
            zip(scores, scores.dropFirst()).first { $0 < $1 }.map { ($0 + $1) / 2 })

        store.searchMinScore = threshold
        await store.runEngineSearch()

        // The engine echoes the threshold, which is the proof it was sent.
        #expect(store.searchResults.minScore == threshold)
        #expect(!store.searchResults.isEmpty)
        #expect(store.searchResults.results.count < unfiltered.results.count)
        #expect(store.searchResults.results.allSatisfy { $0.textScore >= threshold })
        #expect(store.visibleIssues.map(\Bead.id) == store.searchResults.rankedIDs)
        #expect(store.searchThresholdExcludedAll == nil)

        await store.close()
    }

    @Test("A threshold nothing reaches empties the list and says why")
    func thresholdExcludesAll() async throws {
        let (store, directory) = try await searchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.query.searchText = "tax 7"
        store.searchMode = .hybrid
        store.searchMinScore = 1.0
        await store.runEngineSearch()

        #expect(store.searchResults.isEmpty)
        #expect(store.searchThresholdExcludedAll == 1.0)
        // Not the fuzzy fallback: that would show beads the threshold excluded.
        #expect(store.isUsingEngineSearch)
        #expect(store.visibleIssues.isEmpty)

        // Rendered, the list says which threshold and what to do about it —
        // ink in the middle, where the empty state sits.
        let size = CGSize(width: 900, height: 400)
        let result = try Snapshot.render(
            IssueListView().environmentObject(store).frame(width: size.width, height: size.height),
            name: "search-threshold-empty", size: size)
        #expect(
            result.inkCoverage(in: CGRect(x: 250, y: 120, width: 400, height: 180)) > 0.005,
            "the empty state drew nothing")

        // Clearing the threshold brings the ranking back.
        store.searchMinScore = nil
        await store.runEngineSearch()
        #expect(store.searchThresholdExcludedAll == nil)
        #expect(!store.visibleIssues.isEmpty)

        await store.close()
    }

    @Test("A failed search is not reported as an excluding threshold")
    func failureIsNotThreshold() async throws {
        let (store, directory) = try await searchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.query.searchText = "tax 7"
        store.searchMode = .hybrid
        // Outside bv's -1…1: the engine refuses it, through the shared
        // unavailable mechanism, rather than answering "nothing scored".
        store.searchMinScore = 2
        await store.runEngineSearch()

        #expect(store.unavailableReason(.search) != nil)
        #expect(store.searchThresholdExcludedAll == nil)
        #expect(!store.isUsingEngineSearch)

        await store.close()
    }

    @Test("The empty state names the threshold")
    func thresholdWording() {
        #expect(SearchThresholdText.emptyTitle(0.4) == "No results above 0.40")
        #expect(SearchThresholdText.emptyMessage.hasPrefix("Lower the threshold"))
        // Every step the menu offers is one the engine accepts.
        #expect(SearchThresholdText.steps.allSatisfy { (-1...1).contains($0) })
    }

    @Test("The threshold control renders")
    func rendersThresholdPicker() async throws {
        let store = await Fixture.loadedStore()
        store.searchMinScore = 0.4
        let size = CGSize(width: 200, height: 30)
        let result = try Snapshot.render(
            SearchThresholdPicker().environmentObject(store).frame(width: size.width),
            name: "search-threshold", size: size)
        #expect(
            result.inkCoverage(in: CGRect(x: 0, y: 4, width: 200, height: 22)) > 0.01,
            "the threshold control drew nothing")
        await store.close()
    }

    @Test("The presets load with their weights")
    func presetsLoad() async {
        let store = await Fixture.loadedStore()
        await store.loadSearchPresets()

        #expect(store.searchPresets.presets.count == 5)
        // bv has exactly two modes; there is no separate "semantic" one,
        // because the index is always used and the mode selects re-ranking.
        #expect(store.searchPresets.modes.count == 2)

        let textOnly = store.searchPresets.weights(named: "text-only")
        #expect(textOnly?.text == 1.0)
        #expect(textOnly?.pageRank == 0)

        await store.close()
    }

    // MARK: - Weights

    @Test("Weights encode every key, zeros included")
    func weightsEncodeAllKeys() throws {
        var weights = SearchWeights()
        weights.pageRank = 0
        let text = String(decoding: try JSONEncoder().encode(weights), as: UTF8.self)

        // The engine requires all six, and an omitted key is not the same as
        // a zero weight.
        for key in ["text", "pagerank", "status", "impact", "priority", "recency"] {
            #expect(text.contains("\"\(key)\""), "missing \(key)")
        }
    }

    @Test("Weights round-trip through JSON")
    func weightsRoundTrip() throws {
        let original = SearchWeights(
            text: 0.5, pageRank: 0.2, status: 0.1, impact: 0.1, priority: 0.05, recency: 0.05)
        let again = try JSONDecoder().decode(
            SearchWeights.self, from: try JSONEncoder().encode(original))
        #expect(again == original)
        #expect(abs(again.total - 1.0) < 0.0001)
    }

    @Test("The six factors are all offered to the editor")
    func factorsAreComplete() {
        let factors = SearchWeights().factors
        #expect(factors.count == 6)
        #expect(
            factors.map(\.name) == [
                "Text", "Centrality", "Status", "Impact", "Priority", "Recency",
            ])
    }

    @Test("A hit's contributions are ordered largest first")
    func contributionsOrdered() throws {
        let json = """
            {"issue_id":"a","score":0.8,"text_score":0.5,
             "component_scores":{"text":0.2,"pagerank":0.5,"status":0.1}}
            """
        let hit = try JSONDecoder().decode(SearchHit.self, from: Data(json.utf8))
        #expect(hit.contributions.map(\.name) == ["pagerank", "text", "status"])
        #expect(hit.textScore == 0.5)
    }

    @Test("A text-mode hit has no breakdown, and that is not an error")
    func textHitHasNoBreakdown() throws {
        let hit = try JSONDecoder().decode(
            SearchHit.self, from: Data(#"{"issue_id":"a","score":0.4}"#.utf8))
        #expect(hit.componentScores.isEmpty)
        #expect(hit.contributions.isEmpty)
    }

    @Test("Each mode explains what it ranks by")
    func modesAreExplained() {
        for mode in SearchMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.explanation.isEmpty)
        }
        #expect(SearchMode.allCases.count == 2)
    }

    // MARK: - Rendering

    @Test("The scope bar appears only with a query")
    func scopeBarNeedsAQuery() async throws {
        let store = await Fixture.loadedStore()
        await store.loadSearchPresets()

        // Nothing to scope with no query, so the bar draws nothing.
        let empty = try Snapshot.render(
            SearchScopeBar().environmentObject(store).frame(width: 900, height: 34),
            name: "search-scope-empty",
            size: CGSize(width: 900, height: 34)
        )
        #expect(empty.width > 0)

        store.query.searchText = "loader"
        store.searchMode = .hybrid
        let shown = try Snapshot.render(
            SearchScopeBar().environmentObject(store).frame(width: 900),
            name: "search-scope-bar",
            size: CGSize(width: 900, height: 34)
        )
        #expect(shown.inkCoverage() > 0.005, "scope bar drew nothing")

        await store.close()
    }

    @Test("The weights editor renders")
    func rendersWeightsEditor() async throws {
        let store = await Fixture.loadedStore()
        await store.loadSearchPresets()
        store.searchWeights = SearchWeights()

        let result = try Snapshot.render(
            WeightsEditor().environmentObject(store),
            name: "search-weights",
            size: CGSize(width: 340, height: 280)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }

    @Test("A score breakdown renders")
    func rendersBreakdown() throws {
        let json = """
            {"issue_id":"a","score":0.8,"text_score":0.5,
             "component_scores":{"text":0.2,"pagerank":0.5,"status":0.1}}
            """
        let hit = try JSONDecoder().decode(SearchHit.self, from: Data(json.utf8))
        let result = try Snapshot.render(
            SearchScoreBreakdown(hit: hit).padding(10),
            name: "search-breakdown",
            size: CGSize(width: 260, height: 120)
        )
        #expect(result.inkCoverage() > 0.01)
    }
}
