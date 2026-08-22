import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Marking beads that are ahead of the last commit.
///
/// The comparison itself is tested in `Dirty beads`. These cover the parts that
/// need a real repository: that `HEAD` is read at all, that a write through
/// `br` shows up, and that the row draws differently.
@MainActor
@Suite("Uncommitted beads")
struct UncommittedBeadsTests {

    @Test("A freshly committed workspace is clean, and knows it")
    func committedWorkspaceIsClean() async throws {
        let (store, directory) = try await Fixture.committedStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.refreshDirtyState()
        // Both halves: known, and empty. "Unknown" would also report zero, and
        // would mean the git read silently failed.
        #expect(store.dirtyBeads.isKnown, "HEAD was not read — nothing to compare against")
        #expect(store.dirtyBeads.isClean)
        #expect(store.dirtyBeads.total == 0)
    }

    @Test("A bead written through br becomes uncommitted; its neighbours do not")
    func writingMakesOneBeadDirty() async throws {
        let (store, directory) = try await Fixture.committedStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try #require(store.visibleIssues.first)
        let untouched = try #require(store.visibleIssues.dropFirst().first)
        let newPriority = target.priority == 0 ? 3 : 0

        let failed = await store.setPriority(newPriority, for: [target.id])
        #expect(failed.isEmpty, "the write failed: \(String(describing: store.loadError))")

        #expect(store.dirtyBeads.isKnown)
        #expect(store.isDirty(target.id), "the edited bead is not marked")
        #expect(
            !store.isDirty(untouched.id),
            "an untouched bead was marked — the comparison is too coarse")
        #expect(store.dirtyBeads.reason(for: target.id) == "Modified since the last commit")
    }

    @Test("A workspace with no repository is unknown, not clean")
    func noRepositoryIsUnknown() async throws {
        // `writableStore` copies the fixture without any git history, which is
        // exactly the case: nothing to compare against.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.refreshDirtyState()
        #expect(!store.dirtyBeads.isKnown)
        #expect(!store.dirtyBeads.isClean, "no history was reported as nothing outstanding")
        await store.close()
    }

    @Test("HEAD is watched, because a commit does not touch the bead file")
    func headIsWatched() async throws {
        // The bead file is unchanged by a commit — `HEAD` moves and every dirty
        // bead becomes clean. The existing watch would never fire, so this
        // asserts the second watch has something to watch.
        let (store, directory) = try await Fixture.committedStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let head = try #require(store.gitHeadPath, "no .git/HEAD found to watch")
        #expect(head.hasSuffix(".git/HEAD"))
        #expect(FileManager.default.fileExists(atPath: head))
    }

    @Test("A marked row draws differently from an unmarked one")
    func markedRowIsTinted() throws {
        // Rendered rather than asserted on a colour constant: the tint has to
        // actually reach the pixels, and it is drawn in `drawBackground`, which
        // only runs during display.
        func render(uncommitted: Bool) throws -> RenderResult {
            let row = BeadRowView(identifier: .init("test.row"))
            row.isUncommitted = uncommitted
            row.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
            let window = NSWindow(
                contentRect: row.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = row
            return try ViewCapture.image(of: row)
        }

        let plain = try render(uncommitted: false)
        let marked = try render(uncommitted: true)
        #expect(
            plain.averageColour() != marked.averageColour(),
            "the marked row is indistinguishable from a plain one")
    }

    @Test("A marked row is subtle, not loud")
    func tintIsSubtle() throws {
        // The whole request was "subtly different". A tint that shouted would
        // read as an error state, and would fight the alternating stripe.
        let row = BeadRowView(identifier: .init("test.row"))
        row.isUncommitted = true
        row.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        let window = NSWindow(
            contentRect: row.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = row
        let marked = try ViewCapture.image(of: row)

        let plainRow = BeadRowView(identifier: .init("test.row"))
        plainRow.frame = row.frame
        let plainWindow = NSWindow(
            contentRect: row.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        plainWindow.contentView = plainRow
        let plain = try ViewCapture.image(of: plainRow)

        let difference = marked.averageColour().distance(to: plain.averageColour())
        #expect(difference > 2, "the tint is invisible (\(difference))")
        #expect(difference < 60, "the tint is not subtle (\(difference))")
    }
}
