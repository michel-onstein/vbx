import Foundation
import VBXAppCore
import VBXCore
import Testing

@testable import VBXUI

/// History correlates beads to commits, so it is only offered where there are
/// commits to correlate.
///
/// The list it is filtered out of is read by all three places a surface is
/// offered — the toolbar picker, the sidebar's Views section and the View menu
/// — because a surface hidden in one and present in another is worse than one
/// always offered.
@MainActor
@Suite("History needs a repository")
struct HistorySurfaceTests {

    @Test("A workspace with no repository does not offer History")
    func withoutARepositoryHistoryIsHidden() async throws {
        // `writableStore` copies the fixture to a temporary directory and
        // commits nothing, so there is no repository anywhere above it.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(!store.hasGitRepository)
        #expect(store.gitRepositoryRoot == nil)
        #expect(!store.availableSurfaces.contains(.history))
        // Everything else is still offered: this hides one surface, not a
        // category of them.
        #expect(store.availableSurfaces.count == ViewSurface.allCases.count - 1)
        #expect(store.availableSurfaces.contains(.list))
    }

    @Test("A workspace in a repository offers it")
    func withARepositoryHistoryIsOffered() async throws {
        let (store, directory) = try await Fixture.committedStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(store.hasGitRepository)
        #expect(store.availableSurfaces.contains(.history))
        #expect(store.availableSurfaces == ViewSurface.allCases)
    }

    @Test("A workspace below the repository root still counts")
    func aSubdirectoryIsStillInTheRepository() async throws {
        // The mistake the cheap check would make. `<workspace>/.git` does not
        // exist for a workspace one level down, but the workspace is in the
        // repository and History works there — so testing a single level would
        // hide a surface that would have worked.
        let (store, directory) = try await Fixture.committedStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent(".beads"),
            to: nested.appendingPathComponent(".beads"))

        let deeper = ProjectStore()
        await deeper.open(path: nested.path)
        defer { deeper.stopWatching() }

        #expect(deeper.isLoaded, "the nested workspace did not open")
        #expect(deeper.hasGitRepository, "a workspace one level down lost its repository")
        #expect(deeper.gitRepositoryRoot == directory.standardizedFileURL.path)
        #expect(deeper.availableSurfaces.contains(.history))
    }

    @Test("A `.git` file counts as much as a `.git` directory")
    func aGitFileIsARepository() async throws {
        // What `.git` is inside a worktree or a submodule: a file holding a
        // `gitdir:` pointer. This repo's own discipline puts every session in a
        // worktree, so the file form is the common case here rather than an
        // exotic one.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(!store.hasGitRepository)

        try "gitdir: /somewhere/else/.git/worktrees/topic\n".write(
            to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let reopened = ProjectStore()
        await reopened.open(path: directory.path)
        defer { reopened.stopWatching() }
        #expect(reopened.hasGitRepository, "a .git file was not recognised as a repository")
        #expect(reopened.availableSurfaces.contains(.history))
    }

    @Test("Opening a repository-less workspace while on History moves off it")
    func theSelectedSurfaceFallsBack() async throws {
        // Otherwise `surface` names a view nothing offers: hidden from every
        // control and still rendered, which is worse than the state being
        // fixed.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        store.surface = .history
        await store.open(path: directory.path)

        #expect(store.surface != .history)
        #expect(store.availableSurfaces.contains(store.surface), "landed on a surface nothing offers")
    }

    @Test("Opening a repository-backed workspace leaves the surface alone")
    func aValidSurfaceIsNotDisturbed() async throws {
        // The fallback must fire on the one case that needs it and no other:
        // an open should not quietly move the user off the view they chose.
        let (store, directory) = try await Fixture.committedStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }

        store.surface = .history
        await store.open(path: directory.path)
        #expect(store.surface == .history)
    }
}
