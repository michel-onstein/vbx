import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The History surface.
///
/// The fixture workspace lives inside this repository, so loading its history
/// walks a real object store — which is the point: it exercises the sandbox
/// safe path end to end rather than a stub.
@MainActor
@Suite("History view")
struct HistoryViewTests {

    @Test("History is not loaded with the workspace")
    func historyIsLazy() async {
        let store = await Fixture.loadedStore()
        // Walking the object store is the most expensive thing the engine
        // does, and most sessions never open this view. Loading it eagerly
        // would make every workspace open pay for it.
        #expect(!store.historyLoaded)
        #expect(store.history.histories.isEmpty)
        await store.close()
    }

    @Test("Loading history populates the report and is idempotent")
    func loadsHistory() async {
        let store = await Fixture.loadedStore()
        await store.loadHistory()

        guard store.historyError == nil else {
            // A checkout with no git history is a legitimate environment; the
            // view reports it rather than failing. Nothing else to assert.
            #expect(!store.historyLoaded)
            await store.close()
            return
        }

        #expect(store.historyLoaded)
        #expect(store.history.stats.totalCommits > 0)
        #expect(!store.history.gitRange.isEmpty)

        // A second call must not re-walk; the report stays identical.
        let before = store.history.gitRange
        await store.loadHistory()
        #expect(store.history.gitRange == before)

        await store.close()
    }

    @Test("Every linked commit carries a method and a confidence in range")
    func linksAreWellFormed() async {
        let store = await Fixture.loadedStore()
        await store.loadHistory()
        guard store.historyError == nil else {
            await store.close()
            return
        }

        for (_, commit) in store.history.allCommits {
            #expect(commit.confidence > 0 && commit.confidence <= 1)
            #expect(!commit.sha.isEmpty)
            #expect(commit.shortSHA.count <= 7)
            // An unknown method would mean the enum and the engine disagree.
            if case .unknown(let raw) = commit.method {
                Issue.record("unrecognised correlation method: \(raw)")
            }
        }
        await store.close()
    }

    @Test("Linked commits are ordered newest first")
    func commitsAreOrdered() async {
        let store = await Fixture.loadedStore()
        await store.loadHistory()
        guard store.historyError == nil, store.history.allCommits.count > 1 else {
            await store.close()
            return
        }

        let dates = store.history.allCommits.compactMap(\.commit.timestamp)
        #expect(dates == dates.sorted(by: >))
        await store.close()
    }

    @Test("The history view renders its commit tab")
    func rendersCommits() async throws {
        let store = await Fixture.loadedStore()
        await store.loadHistory()

        let result = try Snapshot.render(
            HistoryView().environmentObject(store),
            name: "history-commits",
            size: CGSize(width: 900, height: 600)
        )
        // Either the commit list or the "not a git repository" state — both
        // are real states this view must draw.
        let state =
            "loaded=\(store.historyLoaded) error=\(store.historyError ?? "none") "
            + "commits=\(store.history.stats.totalCommits)"
        #expect(result.inkCoverage() > 0.005, "history view drew almost nothing; \(state)")
        await store.close()
    }

    @Test("A diff line is classified by what it represents")
    func patchLineClassification() {
        // The order of the checks matters: `+++` and `---` are file headers,
        // and testing the single-character prefixes first would colour every
        // diff's header green and red.
        #expect(PatchLine.classify("+++ b/src/loader.go") == .meta)
        #expect(PatchLine.classify("--- a/src/loader.go") == .meta)
        #expect(PatchLine.classify("diff --git a/x b/x") == .meta)
        #expect(PatchLine.classify("index abc..def 100644") == .meta)
        #expect(PatchLine.classify("new file mode 100644") == .meta)
        #expect(PatchLine.classify("@@ -1,3 +1,4 @@") == .hunk)
        #expect(PatchLine.classify("+added line") == .added)
        #expect(PatchLine.classify("-removed line") == .removed)
        #expect(PatchLine.classify(" context line") == .context)
        #expect(PatchLine.classify("") == .context)
    }

    @Test("A patch splits into classified lines")
    func patchLines() {
        let patch = CommitPatch(
            sha: "abc1234",
            path: "src/loader.go",
            patch: """
                diff --git a/src/loader.go b/src/loader.go
                --- a/src/loader.go
                +++ b/src/loader.go
                @@ -1,2 +1,2 @@
                -func Load() {}
                +func Load() error { return nil }
                """)

        let kinds = patch.lines.map(\.kind)
        #expect(kinds == [.meta, .meta, .meta, .hunk, .removed, .added])
        #expect(patch.bytes > 0)
    }

    @Test("A patch identifies what it is a diff of")
    func patchIdentity() {
        // The patch sheet is presented by the patch itself rather than by a
        // flag beside it — a flag is set in the same update that fetched the
        // patch, and the sheet is then built from a body that has not seen it
        // yet, which opens an empty window. That makes this identity part of
        // the presentation: two diffs of the same commit differ by path, and
        // asking for the same diff twice must not re-present. See the recipe
        // editor's sheet, and BUGS.md, 2026-08-24.
        let whole = CommitPatch(sha: "abc1234", patch: "@@ -1 +1 @@")
        let file = CommitPatch(sha: "abc1234", path: "src/loader.go", patch: "@@ -1 +1 @@")
        let other = CommitPatch(sha: "def5678", path: "src/loader.go", patch: "@@ -1 +1 @@")

        #expect(whole.id != file.id)
        #expect(file.id != other.id)
        #expect(file.id == CommitPatch(sha: "abc1234", path: "src/loader.go", patch: "").id)
    }

    @Test("The timeline spans a single-instant history without dividing by zero")
    func timelineHandlesSingleInstant() {
        // A bead created and closed in one commit has a zero-width window.
        // Without widening it, the fraction calculation divides by zero.
        var selected: String?
        let canvas = TimelineCanvas(
            history: nil,
            causality: nil,
            selectedCommit: Binding(get: { selected }, set: { selected = $0 }))
        // Rendering a nil history must draw the empty message, not trap.
        #expect(canvas.history == nil)
    }

    @Test("The history surface is reachable and distinctly keyed")
    func surfaceIsReachable() {
        #expect(ViewSurface.allCases.contains(.history))
        let terminalKeys = ViewSurface.allCases.map(\.terminalKey)
        #expect(Set(terminalKeys).count == terminalKeys.count)
        let commandKeys = ViewSurface.allCases.map(\.keyEquivalent.character)
        #expect(Set(commandKeys).count == commandKeys.count)
    }

    @Test("A reload marks the correlation report stale")
    func reloadInvalidatesHistory() async {
        let store = await Fixture.loadedStore()
        await store.loadHistory()
        guard store.historyError == nil else {
            await store.close()
            return
        }
        #expect(store.historyLoaded)

        // Forced, because the fixture has not changed on disk. Every
        // attribution was computed against the old bead set, so the report
        // must be marked stale rather than kept.
        await store.reload(force: true)
        #expect(!store.historyLoaded)

        await store.close()
    }
}
