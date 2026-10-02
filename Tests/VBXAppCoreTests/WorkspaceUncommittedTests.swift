import Foundation
import Testing
import VBXCore

@testable import VBXAppCore

/// Uncommitted marks in a multi-repository workspace (vbx-d1c).
///
/// The marks were computed against the repository holding
/// `.bv/workspace.yaml`, and only that repository's `.git` was watched. A
/// member is normally a repository of its own, so its beads were compared
/// against the wrong history — or none — and a commit in it moved a `HEAD`
/// nothing was watching. These tests build two member repositories under a
/// root that is in no repository, which is where the old path had nothing to
/// compare against at all.

private let apiBead =
    #"{"id":"1","title":"API endpoint","status":"open","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z"}"#
private let webBead =
    #"{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0,"created_at":"2026-01-01T00:00:00Z"}"#
private let webBeadRenamed =
    #"{"id":"1","title":"Web form, renamed","status":"open","issue_type":"task","priority":0,"created_at":"2026-01-01T00:00:00Z"}"#

private func writeMember(_ root: URL, _ name: String, _ lines: String...) throws {
    let beads = root.appendingPathComponent(name).appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(
        to: beads.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)
}

/// Runs git in `directory` with a fixed identity, so the test depends on
/// nothing the machine has configured and writes nothing into its config.
private func git(_ arguments: [String], in directory: URL) throws {
    let environment = [
        "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
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
    if process.terminationStatus != 0 {
        throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments) failed"])
    }
}

private func commitMember(_ root: URL, _ name: String, _ message: String) throws {
    let member = root.appendingPathComponent(name)
    try git(["add", "-A"], in: member)
    try git(["commit", "-qm", message], in: member)
}

/// Two member repositories, each with its beads committed, and the
/// configuration naming them. `inRepository` lists the members that get a
/// repository; the rest have none.
private func twoRepoWorkspace(inRepository: Set<String> = ["api", "web"]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-members-\(UUID().uuidString)")
    try writeMember(root, "api", apiBead)
    try writeMember(root, "web", webBead)
    for member in ["api", "web"] where inRepository.contains(member) {
        try git(["init", "-q"], in: root.appendingPathComponent(member))
        try commitMember(root, member, "\(member) beads")
    }
    let bv = root.appendingPathComponent(".bv")
    try FileManager.default.createDirectory(at: bv, withIntermediateDirectories: true)
    var yaml = "name: Two repositories\nrepos:\n"
    for member in ["api", "web"] {
        yaml += "  - name: \(member)\n    path: \(member)\n    prefix: \"\(member)-\"\n"
    }
    try yaml.write(
        to: bv.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    return root
}

@MainActor
private func eventually(
    timeout: TimeInterval = 20, poke: (() -> Void)? = nil, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var lastPoke = Date()
    while Date() < deadline {
        if condition() { return true }
        if let poke, Date().timeIntervalSince(lastPoke) > 2 {
            poke()
            lastPoke = Date()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

private func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

@MainActor
@Test("Each member's repository is watched for commits")
func everyMemberRepositoryIsWatched() async throws {
    let root = try twoRepoWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: root.path)
    #expect(store.isLoaded)
    // The root is in no repository; before vbx-d1c that meant no git watch.
    #expect(store.isWatchingGit, "a workspace whose members are repositories is not watched for commits")

    let watched = Set(store.watchedGitDirectories.map(resolved))
    for member in ["api", "web"] {
        let expected = resolved(root.appendingPathComponent(member).appendingPathComponent(".git").path)
        #expect(watched.contains(expected), "\(member)/.git is not watched: \(watched.sorted())")
    }

    await store.close()
}

@MainActor
@Test("An edit in a member is marked, and a commit in that member clears it")
func memberCommitClearsItsMarks() async throws {
    let root = try twoRepoWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: root.path)
    #expect(store.isLoaded)
    // Was unknown: the snapshot looked for the members' beads in a repository
    // the workspace root is not even in.
    #expect(store.dirtyBeads.isKnown, "a committed multi-repository workspace has nothing to compare against")
    #expect(store.dirtyBeads.isClean, "freshly committed members show \(store.dirtyBeads.summary())")

    try await Task.sleep(for: .milliseconds(400))

    // An edit the way `br` makes one: the bead watch reloads, and the reload
    // recomputes the marks.
    let edit: () -> Void = { try? writeMember(root, "web", webBeadRenamed) }
    edit()
    #expect(
        await eventually(poke: edit) { store.dirtyBeads.isDirty("web-1") },
        "the edited member bead was never marked: \(store.dirtyBeads.summary())")
    #expect(store.dirtyBeads.marked == ["web-1"], "marked \(store.dirtyBeads.marked.sorted())")

    // The commit changes no bead, so only the member's git watch can notice.
    try commitMember(root, "web", "rename the form")
    let cleared = await eventually { store.dirtyBeads.isClean }
    #expect(cleared, "a commit in the member left its mark standing: \(store.dirtyBeads.summary())")

    await store.close()
}

@MainActor
@Test("A member with no repository is left unmarked, not marked as added")
func memberWithoutRepositoryIsNotAdded() async throws {
    let root = try twoRepoWorkspace(inRepository: ["api"])
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: root.path)
    #expect(store.isLoaded)
    #expect(store.dirtyBeads.isKnown)
    #expect(
        !store.dirtyBeads.isDirty("web-1"),
        "a member with no history to compare against was marked as added")
    #expect(store.dirtyBeads.isClean, "\(store.dirtyBeads.summary())")

    await store.close()
}
