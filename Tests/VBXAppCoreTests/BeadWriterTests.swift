import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// The first write path in vbx.
///
/// The runner is injected throughout, so these assert the command vbx *sends*
/// without needing `br` installed and without writing into a real workspace.
/// The argument vector is the contract with `br`: a wrong flag is a silent
/// no-op or a different edit than the one requested.
@MainActor
@Test("A priority change sends exactly the expected br command")
func priorityCommandIsExact() async throws {
    var sent: [[String]] = []
    var directories: [String] = []

    let writer = BeadWriter(
        locate: { "/fake/br" },
        runner: { argv, workspace in
            sent.append(argv)
            directories.append(workspace)
            return .init(status: 0, standardOutput: "{}", standardError: "")
        })

    try await writer.setPriority(1, for: "vbx-3", in: "/tmp/workspace")

    #expect(sent == [["/fake/br", "update", "vbx-3", "--priority", "1", "--json"]])
    // Run *in* the workspace: br discovers .beads from the working directory,
    // so running anywhere else edits a different workspace or none.
    #expect(directories == ["/tmp/workspace"])
}

@MainActor
@Test("The published argument vector matches what is actually sent")
func publishedArgumentsMatch() async throws {
    // Two copies of the flags would drift; this pins them together.
    var sent: [[String]] = []
    let writer = BeadWriter(
        locate: { "/fake/br" },
        runner: { argv, _ in
            sent.append(argv)
            return .init(status: 0, standardOutput: "", standardError: "")
        })

    try await writer.setPriority(4, for: "vbx-9", in: "/tmp/w")
    #expect(Array(sent[0].dropFirst()) == BeadWriter.priorityArguments(4, for: "vbx-9"))
}

@MainActor
@Test("A failing command surfaces its message instead of passing silently")
func failureIsReported() async {
    let writer = BeadWriter(
        locate: { "/fake/br" },
        runner: { _, _ in
            .init(status: 1, standardOutput: "", standardError: "no such issue: vbx-nope\n")
        })

    await #expect(throws: BeadWriter.WriteError.self) {
        try await writer.setPriority(2, for: "vbx-nope", in: "/tmp/w")
    }
}

@MainActor
@Test("Without br the writer refuses rather than pretending")
func missingBRIsRefused() async {
    let writer = BeadWriter(locate: { nil }, runner: { _, _ in
        Issue.record("the runner was called with no br installed")
        return .init(status: 0, standardOutput: "", standardError: "")
    })

    #expect(!writer.isAvailable)
    await #expect(throws: BeadWriter.WriteError.self) {
        try await writer.setPriority(0, for: "vbx-1", in: "/tmp/w")
    }
}

@MainActor
@Test("Editing is refused while time travelling, and without br")
func editingGuards() async {
    let store = ProjectStore()
    store.skipPhase2 = true
    store.writer = BeadWriter(locate: { nil }, runner: { _, _ in
        .init(status: 0, standardOutput: "", standardError: "")
    })

    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
    await store.open(path: fixture)

    // No br: a normal state, explained rather than silently inert.
    #expect(!store.canEditBeads)
    #expect(store.editingUnavailableReason?.contains("Install br") == true)

    // With br, editing is available again.
    store.writer = BeadWriter(locate: { "/fake/br" }, runner: { _, _ in
        .init(status: 0, standardOutput: "", standardError: "")
    })
    #expect(store.canEditBeads)
    #expect(store.editingUnavailableReason == nil)

    await store.close()
}

@MainActor
@Test("The command runs in the workspace, not in the .beads directory")
func workspaceDirectoryIsTheProjectRoot() async {
    // br discovers .beads from its working directory. Handing it
    // `<workspace>/.beads` would make it look for `<workspace>/.beads/.beads`.
    let store = ProjectStore()
    store.skipPhase2 = true
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
    await store.open(path: fixture)

    #expect(store.workspaceDirectory == fixture)
    await store.close()
}

@MainActor
@Test("br is looked for in ~/.local/bin, where its installer puts it")
func brCandidatesIncludeLocalBin() {
    // A Finder launch inherits no shell PATH, so the fixed list is all there
    // is. Without ~/.local/bin, a br installed there reads as missing and
    // every edit fails from the Dock while working from a terminal (vbx-9y7).
    let candidates = BeadWriter.brCandidates(path: nil, home: "/Users/someone")
    #expect(
        candidates == [
            "/Users/someone/.local/bin/br",
            "/Users/someone/.cargo/bin/br",
            "/opt/homebrew/bin/br",
            "/usr/local/bin/br",
        ])
}

@MainActor
@Test("PATH is searched before the fixed install locations, in its own order")
func brCandidatesPreferPath() {
    let candidates = BeadWriter.brCandidates(path: "/a/bin:/b/bin", home: "/h")
    #expect(Array(candidates.prefix(3)) == ["/a/bin/br", "/b/bin/br", "/h/.local/bin/br"])
}
