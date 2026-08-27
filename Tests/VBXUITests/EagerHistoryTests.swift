import Foundation
import VBXAppCore
import VBXCore
import Testing

@testable import VBXUI

/// The correlation report is loaded when a workspace opens, and kept current.
///
/// Before this it was loaded only by the History view's `.task`, so anything
/// else that wanted per-bead commit data found it empty and could not tell that
/// from a bead with no commits.
@MainActor
@Suite("Eager history")
struct EagerHistoryTests {

    /// Waits for the background walk, which is deliberately not awaited by
    /// `open` — polling rather than a fixed sleep, so a slow machine does not
    /// turn into a flaky test.
    ///
    /// The budget is generous on purpose. The claim under test is that the walk
    /// runs without the History view, not that it runs within any particular
    /// time, and under the full parallel suite these tests are starved: 38
    /// suites at once, and this one's own setup (`git init`, a commit, an open
    /// and a Phase-2 computation) took ~65s in a run where the walk was still
    /// in flight at ten. A tight budget here measures the machine's load, not
    /// the feature.
    private func waitForHistory(_ store: ProjectStore, seconds: Double = 120) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if store.historyLoaded || store.historyError != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test("Opening a workspace loads the report without the History view")
    func openLoadsTheReport() async throws {
        let (store, directory) = try await Fixture.committedStore(eagerHistory: true)
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        await waitForHistory(store)
        #expect(store.historyLoaded, "the walk did not run: \(String(describing: store.historyError))")
        #expect(store.historyError == nil)
    }

    @Test("A workspace with no repository is not loaded, and not an error")
    func noRepositoryIsNotAFailure() async throws {
        // The distinction the column depends on: nothing to walk is a normal
        // state, and recording a failure would make it look like something
        // went wrong.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(!store.hasGitRepository)
        // Given a moment in case a walk was started anyway.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!store.historyLoaded)
        #expect(store.historyError == nil, "no repository was reported as a failure")
    }

    @Test("The three states are distinguishable from outside")
    func statesAreDistinguishable() async throws {
        // A bead with no commits and a report that has not been read must not
        // look alike to whatever renders them — the rule vbx-cbw's column
        // stands on.
        let (store, directory) = try await Fixture.committedStore(eagerHistory: true)
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        await waitForHistory(store)
        #expect(store.historyLoaded)
        #expect(!store.historyLoading)

        let (bare, bareDirectory) = try await Fixture.writableStore()
        defer {
            bare.stopWatching()
            try? FileManager.default.removeItem(at: bareDirectory)
        }
        #expect(!bare.historyLoaded, "an unwalked workspace claims a loaded report")
    }

    @Test("HEAD is watched at the path git actually keeps it")
    func headPathResolvesThroughTheRepositoryRoot() async throws {
        let (store, directory) = try await Fixture.committedStore(eagerHistory: true)
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        let head = try #require(store.gitHeadPath, "no HEAD to watch")
        #expect(FileManager.default.fileExists(atPath: head))
        #expect(head.hasSuffix("/HEAD"))
    }

    @Test("A .git file's gitdir pointer is followed")
    func aWorktreeStyleGitFileIsFollowed() async throws {
        // The case that silently did not work: inside a worktree `.git` is a
        // file holding `gitdir:`, and HEAD lives at the far end of it. Every
        // session in this project works in a worktree, so this was the common
        // case, not the exotic one.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        // A real git directory to point at, with a HEAD in it.
        let elsewhere = directory.appendingPathComponent("pretend-gitdir")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: elsewhere.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(elsewhere.path)\n".write(
            to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let reopened = ProjectStore()
        reopened.loadsHistoryEagerly = true
        await reopened.open(path: directory.path)
        defer { reopened.stopWatching() }

        let head = try #require(
            reopened.gitHeadPath, "the gitdir pointer was not followed")
        #expect(head == elsewhere.appendingPathComponent("HEAD").path)
    }

    @Test("A .git file that is not a gitdir pointer installs no watch")
    func anUnreadableGitFileIsRefused() async throws {
        // Guessing at a `.git` file this does not understand would install a
        // watch on a path that does not exist.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        try "something else entirely\n".write(
            to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let reopened = ProjectStore()
        reopened.loadsHistoryEagerly = true
        await reopened.open(path: directory.path)
        defer { reopened.stopWatching() }
        #expect(reopened.gitHeadPath == nil)
    }

    @Test("A walk cannot publish into a workspace it did not start in")
    func aStaleWalkPublishesNothing() async throws {
        // Opening a second workspace while the first one's walk is in flight
        // must not leave the first one's report in the second one's store —
        // the user would be looking at another project's commits.
        let (store, first) = try await Fixture.committedStore(eagerHistory: true)
        let (_, second) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        await waitForHistory(store)
        #expect(store.historyLoaded)

        // The second workspace has no repository, so a correct implementation
        // ends with nothing loaded rather than the first one's report.
        await store.open(path: second.path)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(!store.hasGitRepository)
        #expect(
            !store.historyLoaded,
            "the previous workspace's report survived into this one")
    }
}
