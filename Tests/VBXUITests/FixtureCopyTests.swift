import Foundation
import Testing
import VBXAppCore
import VBXCore

private typealias Bead = VBXCore.Issue

/// Regression tests for vbx-fcq: the first `br` command against a freshly
/// copied fixture could not find any bead.
///
/// Every test that writes through `br` copies the fixture first, so when the
/// copy was broken they all failed together — 24 assertions across title
/// editing, priority editing and uncommitted beads — on a clean `main`. See
/// BUGS.md, 2026-10-01.
@MainActor
@Suite("Fixture copies")
struct FixtureCopyTests {
    @Test("A copy keeps the JSONL and leaves br's local cache behind")
    func copyDropsBRCache() throws {
        // A source workspace carrying the state a checkout picks up once
        // anyone runs `br` in it: a database, its WAL, and a lock.
        let source = try Fixture.copy(prefix: "vbx-source")
        defer { try? FileManager.default.removeItem(at: source) }
        let sourceBeads = source.appendingPathComponent(".beads")
        for name in ["beads.db", "beads.db-wal", ".write.lock"] {
            try Data("stale".utf8).write(to: sourceBeads.appendingPathComponent(name))
        }

        let copy = try Fixture.copy(from: source.path)
        defer { try? FileManager.default.removeItem(at: copy) }

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: copy.appendingPathComponent(".beads").path)
        #expect(entries == ["issues.jsonl"], "the copy kept \(entries)")
    }

    @Test("A copy leaves bv's local state behind and keeps its configuration")
    func copyDropsBVState() throws {
        // vbx-n86: a semantic index left in `Fixtures/demo` went into every
        // copy, and the history fixture committed it into its root commit,
        // which changed what the orphan report counted.
        let source = try Fixture.copy(prefix: "vbx-source")
        defer { try? FileManager.default.removeItem(at: source) }
        let bv = source.appendingPathComponent(".bv")
        try FileManager.default.createDirectory(
            at: bv.appendingPathComponent("semantic"), withIntermediateDirectories: true)
        try Data("index".utf8).write(to: bv.appendingPathComponent("semantic/index-hash-384.bvvi"))
        try Data("{}".utf8).write(to: bv.appendingPathComponent("baseline.json"))
        try Data("recipes: {}\n".utf8).write(to: bv.appendingPathComponent("recipes.yaml"))

        let copy = try Fixture.copy(from: source.path)
        defer { try? FileManager.default.removeItem(at: copy) }

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: copy.appendingPathComponent(".bv").path)
        #expect(entries == ["recipes.yaml"], "the copy kept \(entries)")
    }

    @Test("A write is the first br command a cold copy can take")
    func firstCommandIsAWrite() async throws {
        let directory = try Fixture.copy()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BeadWriter()
        try #require(writer.isAvailable, "br was not found")

        // vbx-12 is P0 in the fixture, so 3 cannot pass as a no-op.
        // No `br list` beforehand: priming the copy is what hid the bug, since
        // a read imported the JSONL and the write after it then succeeded.
        try await writer.setPriority(3, for: "vbx-12", in: directory.path)

        let store = ProjectStore()
        await store.open(path: directory.path)
        let bead: Bead? = store.issues.first { $0.id == "vbx-12" }
        #expect(bead?.priority == 3, "vbx-12 is \(String(describing: bead?.priority))")
    }

    @Test("br can write to the readiness fixture")
    func readinessFixtureIsWritable() async throws {
        // br validates the whole workspace on import and rejects all of it for
        // one bad row — a dependency without created_at, or one naming a bead
        // that does not exist (which is why the fixture's missing blocker is an
        // `external:` reference). A fixture br refuses is one no write test can
        // use, and the refusal reads as an app bug.
        let directory = try Fixture.copy(from: Fixture.readinessPath, prefix: "vbx-readiness")
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BeadWriter()
        try #require(writer.isAvailable, "br was not found")

        // rdy-17 is P2 and sits two parent-child edges down.
        try await writer.setPriority(0, for: "rdy-17", in: directory.path)

        let store = ProjectStore()
        store.skipPhase2 = true
        await store.open(path: directory.path)
        #expect(store.issues.count == 21, "a write dropped records: \(store.issues.count)")
        let bead: Bead? = store.issues.first { $0.id == "rdy-17" }
        #expect(bead?.priority == 0, "rdy-17 is \(String(describing: bead?.priority))")
        await store.close()
    }
}
