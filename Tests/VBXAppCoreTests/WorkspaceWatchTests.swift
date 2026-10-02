import Foundation
import Testing
import VBXCore

@testable import VBXAppCore

/// Live reload in a multi-repository workspace (vbx-zot).
///
/// A workspace session's source is `.bv/workspace.yaml`, and the watch used to
/// follow that file's directory alone. Every member's beads live in its own
/// repository, so nothing written to one ever reloaded — the store loaded,
/// listed and reported that it was watching, and went on showing the old
/// beads. These tests write where a `br` run in a member would.

/// Two member repositories and a root `.beads`, under one `.bv/workspace.yaml`.
private func scratchMultiRepoWorkspace() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-workspace-\(UUID().uuidString)")
    let manager = FileManager.default
    try writeMember(root, "api", #"{"id":"1","title":"API endpoint","status":"open","issue_type":"task","priority":1}"#)
    try writeMember(root, "web", #"{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0}"#)
    try manager.createDirectory(
        at: root.appendingPathComponent(".beads"), withIntermediateDirectories: true)
    try writeConfig(root, members: ["api", "web"])
    return root
}

/// What the tests open: the configuration itself. The root holds a `.beads`
/// for feedback.json, so opening the folder would take it for a single
/// repository, as bv's discovery does (ADR-026); choosing the configuration
/// is how the app opens such a workspace.
private func configPath(_ root: URL) -> String {
    root.appendingPathComponent(".bv/workspace.yaml").path
}

private func writeMember(_ root: URL, _ name: String, _ lines: String...) throws {
    let beads = root.appendingPathComponent(name).appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(
        to: beads.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)
}

private func writeConfig(_ root: URL, members: [String]) throws {
    let bv = root.appendingPathComponent(".bv")
    try FileManager.default.createDirectory(at: bv, withIntermediateDirectories: true)
    var yaml = "name: Scratch workspace\nrepos:\n"
    for member in members {
        yaml += "  - name: \(member)\n    path: \(member)\n    prefix: \"\(member)-\"\n"
    }
    try yaml.write(
        to: bv.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
}

/// Waits for `condition`, re-applying `poke` every couple of seconds — the
/// same shape as ExternalChangeTests', for the same reasons: FSEvents latency,
/// a debounce and a hop to the main actor, under a parallel suite.
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

@MainActor
private func hasTitle(_ store: ProjectStore, _ title: String) -> Bool {
    store.issues.contains { $0.title == title }
}

private func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

@MainActor
@Test("A workspace watches every member's beads and the root .beads")
func workspaceWatchCoversEveryMember() async throws {
    let root = try scratchMultiRepoWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: configPath(root))
    #expect(store.isLoaded)
    #expect(store.isWatching)

    let watched = Set(store.watchedDirectories.map(resolved))
    for expected in [".bv", ".beads", "api/.beads", "web/.beads"] {
        let path = resolved(root.appendingPathComponent(expected).path)
        #expect(watched.contains(path), "\(expected) is not watched: \(watched.sorted())")
    }

    await store.close()
}

@MainActor
@Test("A bead written to a workspace member reaches the open workspace")
func memberEditReachesTheStore() async throws {
    let root = try scratchMultiRepoWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: configPath(root))
    #expect(store.isLoaded)
    let before = store.issues.count

    try await Task.sleep(for: .milliseconds(400))

    let write: () -> Void = {
        try? writeMember(
            root, "web",
            #"{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0}"#,
            #"{"id":"2","title":"Added in a member","status":"open","issue_type":"task","priority":2}"#)
    }
    write()

    let arrived = await eventually(poke: write) { hasTitle(store, "Added in a member") }
    #expect(arrived, "a write to a member never reached the store — only .bv is watched")
    #expect(store.issues.count == before + 1)

    await store.close()
}

@MainActor
@Test("The root feedback.json reloads a workspace")
func rootFeedbackReloadsTheWorkspace() async throws {
    let root = try scratchMultiRepoWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: configPath(root))
    #expect(store.isLoaded)
    #expect(store.lastReloadAt == nil, "precondition: nothing has reloaded yet")

    try await Task.sleep(for: .milliseconds(400))

    // Feedback is outside the bead hash; the engine reports it as a change of
    // its own, and `reload` stamps `lastReloadAt` only for a change.
    let file = root.appendingPathComponent(".beads/feedback.json")
    var round = 0
    let write: () -> Void = {
        round += 1
        let body = #"{"version":1,"events":[{"issue_id":"web-1","action":"accept","score":0.\#(round)}]}"#
        try? body.write(to: file, atomically: true, encoding: .utf8)
    }
    write()

    let reloaded = await eventually(poke: write) { store.lastReloadAt != nil }
    #expect(reloaded, "an edit to the root feedback.json never reloaded the workspace")

    await store.close()
}

@MainActor
@Test("A member added to workspace.yaml is watched from then on")
func addedMemberIsWatched() async throws {
    let root = try scratchMultiRepoWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: configPath(root))
    #expect(store.isLoaded)

    try await Task.sleep(for: .milliseconds(400))

    // A new member arrives through the config, which `.bv/` already covered.
    try writeMember(root, "docs", #"{"id":"1","title":"Docs page","status":"open","issue_type":"docs","priority":2}"#)
    let addMember: () -> Void = { try? writeConfig(root, members: ["api", "web", "docs"]) }
    addMember()
    #expect(await eventually(poke: addMember) { hasTitle(store, "Docs page") })

    let docs = resolved(root.appendingPathComponent("docs/.beads").path)
    #expect(store.watchedDirectories.map(resolved).contains(docs), "the new member is not watched")

    // And the point of watching it: a write there is now heard.
    let write: () -> Void = {
        try? writeMember(
            root, "docs",
            #"{"id":"1","title":"Docs page","status":"open","issue_type":"docs","priority":2}"#,
            #"{"id":"2","title":"Docs index","status":"open","issue_type":"docs","priority":2}"#)
    }
    write()
    #expect(
        await eventually(poke: write) { hasTitle(store, "Docs index") },
        "a write to the newly added member never arrived")

    await store.close()
}
