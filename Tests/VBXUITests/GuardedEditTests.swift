import Foundation
import Testing
@testable import VBXAppCore
import VBXCore

private typealias Bead = VBXCore.Issue

/// Single-bead edits guarded by `br update --if-unchanged` (vbx-7fh), against
/// whichever `br` is installed.
///
/// The guard exists from `br` 0.7.0; older ones get the unguarded write. These
/// assert the right outcome for *either*, so they pass on 0.6.0 and prove the
/// guard on 0.7.x — run them with a 0.7 `br` first on `PATH` to exercise it.
@MainActor
@Suite("Guarded edits")
struct GuardedEditTests {

    @Test("updated_at reaches the store at br's full precision, not a Date's")
    func stampKeepsMicroseconds() async throws {
        // br stamps microseconds (or finer) and --if-unchanged compares them,
        // so a stamp truncated to milliseconds would be a conflict every time.
        let directory = try Fixture.copy(prefix: "vbx-stamp")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".beads/issues.jsonl")
        let precise = "2026-10-01T22:33:13.885481Z"
        var found = false
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map { line -> String in
                guard
                    var record = try JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any],
                    record["id"] as? String == "vbx-12"
                else { return String(line) }
                found = true
                record["updated_at"] = precise
                let data = try JSONSerialization.data(withJSONObject: record)
                return String(decoding: data, as: UTF8.self)
            }
        try #require(found, "the fixture no longer has vbx-12")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let store = ProjectStore()
        store.skipPhase2 = true
        await store.open(path: directory.path)
        defer { Task { await store.close() } }
        let bead: Bead? = store.issues.first { $0.id == "vbx-12" }
        #expect(bead?.updatedAtStamp == precise)
    }

    @Test("A guarded edit of the record vbx just read lands")
    func freshStampLands() async throws {
        let directory = try Fixture.copy(prefix: "vbx-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BeadWriter()
        try #require(writer.isAvailable, "br was not found")
        // A first write so updated_at carries br's own sub-second stamp.
        try await writer.setPriority(3, for: "vbx-12", in: directory.path)

        let store = ProjectStore()
        store.skipPhase2 = true
        await store.open(path: directory.path)
        defer { Task { await store.close() } }

        let wrote = await store.setPriority(1, for: "vbx-12")
        #expect(wrote, "refused: \(String(describing: store.loadError))")
        let bead: Bead? = store.issues.first { $0.id == "vbx-12" }
        #expect(bead?.priority == 1)
    }

    @Test("A stale stamp is refused by a br that guards, and written by one that cannot")
    func staleStampOutcome() async throws {
        let directory = try Fixture.copy(prefix: "vbx-stale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BeadWriter()
        try #require(writer.isAvailable, "br was not found")
        try await writer.setPriority(3, for: "vbx-12", in: directory.path)

        let before = ProjectStore()
        before.skipPhase2 = true
        await before.open(path: directory.path)
        let stale = try #require(before.issues.first { $0.id == "vbx-12" }?.updatedAtStamp)
        await before.close()

        // Another writer — an agent — changes the bead after vbx read it.
        try await BeadWriter().setPriority(2, for: "vbx-12", in: directory.path)

        let guards = await writer.supportsIfUnchanged(in: directory.path)
        do {
            try await writer.setPriority(4, for: "vbx-12", in: directory.path, ifUnchangedSince: stale)
            #expect(!guards, "a br with --if-unchanged overwrote a newer record")
        } catch BeadWriter.WriteError.changedSinceRead(let id) {
            #expect(guards)
            #expect(id == "vbx-12")
        }

        let after = ProjectStore()
        after.skipPhase2 = true
        await after.open(path: directory.path)
        let bead: Bead? = after.issues.first { $0.id == "vbx-12" }
        #expect(bead?.priority == (guards ? 2 : 4))
        await after.close()
    }
}
