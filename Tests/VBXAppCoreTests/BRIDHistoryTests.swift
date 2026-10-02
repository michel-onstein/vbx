import Foundation
import Testing
import VBXCore
import VBXEngine

@testable import VBXAppCore

/// A commit naming a br-minted id is linked to it in the app (vbx-znj).
///
/// bv's explicit-id patterns need a numeric suffix, so `vbx-8ou` named in a
/// message is invisible to them; bv's remedy is `--id-pattern`. The app has no
/// command line, so it opens every workspace with one pattern per id prefix
/// the workspace declares — here `.beads/config.yaml`'s `issue_prefix`.
/// See ADR-027.

private func record(_ id: String, _ title: String) -> String {
    #"{"id":"\#(id)","title":"\#(title)","status":"open","issue_type":"task","priority":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#
}

/// Runs git with a fixed identity and date, depending on nothing the machine
/// has configured.
private func git(_ arguments: [String], in directory: URL, author: String, date: String) throws {
    let environment = [
        "GIT_AUTHOR_NAME": author, "GIT_AUTHOR_EMAIL": "\(author)@example.invalid",
        "GIT_COMMITTER_NAME": author, "GIT_COMMITTER_EMAIL": "\(author)@example.invalid",
        "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    ].merging(ProcessInfo.processInfo.environment) { mine, _ in mine }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "commit.gpgsign=false"] + arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments)"])
    }
}

/// A repository whose beads carry br-minted ids, and a commit by someone
/// else naming one of them without touching the beads file.
private func brIDRepository(issuePrefix: String?) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-brid-\(UUID().uuidString)")
    let beads = root.appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    if let issuePrefix {
        try "issue_prefix: \(issuePrefix)\n".write(
            to: beads.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }
    try (record("vbx-8ou", "Profile the cache") + "\n" + record("vbx-k7j", "Split the loader") + "\n")
        .write(to: beads.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)
    try git(["init", "-q"], in: root, author: "ada", date: "2026-08-01T10:00:00Z")
    try git(["add", "-A"], in: root, author: "ada", date: "2026-08-01T10:00:00Z")
    try git(["commit", "-qm", "Add the beads"], in: root, author: "ada", date: "2026-08-01T10:00:00Z")

    let sources = root.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try "let cacheSize = 64\n".write(
        to: sources.appendingPathComponent("Cache.swift"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: root, author: "grace", date: "2026-08-02T10:00:00Z")
    try git(["commit", "-qm", "Grow the cache for vbx-8ou"], in: root, author: "grace",
            date: "2026-08-02T10:00:00Z")
    return root
}

@MainActor
@Suite("br-minted ids in history")
struct BRIDHistoryTests {
    @Test("The app links a commit naming a br id, from the workspace's issue_prefix")
    func appLinksABRID() async throws {
        let directory = try brIDRepository(issuePrefix: "vbx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore()
        store.loadsHistoryEagerly = false
        await store.open(path: directory.path)
        await store.loadHistory()

        #expect(store.historyError == nil, "\(store.historyError ?? "")")
        let commits = store.commits(for: "vbx-8ou")
        #expect(commits.map(\.message) == ["Grow the cache for vbx-8ou"])
        #expect(commits.first?.method == .explicitID)
        #expect(!store.orphans.candidates.contains { $0.message == "Grow the cache for vbx-8ou" },
                "a linked commit is still reported as an orphan")
        await store.close()
    }

    @Test("Without an issue_prefix nothing is registered, and bv's patterns miss the id")
    func noPrefixNoLink() async throws {
        let directory = try brIDRepository(issuePrefix: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore()
        store.loadsHistoryEagerly = false
        await store.open(path: directory.path)
        await store.loadHistory()

        #expect(store.historyError == nil, "\(store.historyError ?? "")")
        #expect(store.commits(for: "vbx-8ou").isEmpty)
        await store.close()
    }

    @Test("vbx-cli's --id-pattern: a pattern links it, and one that does not compile is bv's error")
    func engineIDPatterns() async throws {
        let directory = try brIDRepository(issuePrefix: nil)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = BeadsEngine()
        _ = try await engine.open(path: directory.path, skipPhase2: true, idPatterns: [#"vbx-[a-z0-9]{3}"#])
        let report = try await engine.history()
        #expect(report.histories["vbx-8ou"]?.commits.map(\.message) == ["Grow the cache for vbx-8ou"])
        await engine.close()

        let refused = BeadsEngine()
        do {
            _ = try await refused.open(path: directory.path, idPatterns: ["("])
            Testing.Issue.record("an --id-pattern that does not compile was accepted")
        } catch EngineError.openFailed(let message) {
            #expect(message == "Invalid --id-pattern \"(\": error parsing regexp: missing closing ): `(`")
        }
    }
}
