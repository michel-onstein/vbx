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

// MARK: - br 0.7.4's "recovery in progress" (vbx-1sw)

/// What `br` 0.7.4 printed, verbatim, on the write after `sqlite3` had opened
/// the database: the error JSON on stdout and the pager's retry log on stderr
/// (one of the 24 lines kept, the hint shortened). Captured 2026-10-01.
private let recoveryStdout = """
    {
      "error": {
        "code": "DATABASE_ERROR",
        "message": "Database error: database is busy (recovery in progress)",
        "hint": "The WAL index (.beads/beads.db-shm) must be rebuilt before br can read the database.",
        "retryable": false,
        "context": null
      }
    }
    """
private let recoveryStderr = """
    2026-10-01T19:37:05.737978Z ERROR fsqlite_pager::pager: group-commit callback failed \
    after durable mutation started; retaining RESERVED and leaving epoch FLUSHING epoch=1 \
    error=database is busy (recovery in progress)

    """

@MainActor
@Test("A write that fails with 'recovery in progress' is sent again, once, and succeeds")
func recoveryInProgressIsRetriedOnce() async throws {
    var sent: [[String]] = []
    let writer = BeadWriter(
        locate: { "/fake/br" },
        runner: { argv, _ in
            sent.append(argv)
            return sent.count == 1
                ? .init(status: 2, standardOutput: recoveryStdout, standardError: recoveryStderr)
                : .init(status: 0, standardOutput: "{}", standardError: "")
        })

    try await writer.setPriority(1, for: "vbx-3", in: "/tmp/w")

    let command = ["/fake/br"] + BeadWriter.priorityArguments(1, for: "vbx-3")
    #expect(sent == [command, command])
}

@MainActor
@Test("A second 'recovery in progress' is reported, not retried forever")
func recoveryInProgressRetriesOnlyOnce() async {
    var calls = 0
    let writer = BeadWriter(
        locate: { "/fake/br" },
        runner: { _, _ in
            calls += 1
            return .init(status: 2, standardOutput: recoveryStdout, standardError: recoveryStderr)
        })

    await #expect(throws: BeadWriter.WriteError.self) {
        try await writer.setTitle("New", for: "vbx-3", in: "/tmp/w")
    }
    #expect(calls == 2)
}

@MainActor
@Test("Any other failure is reported at once, without a retry")
func otherFailuresAreNotRetried() async {
    var calls = 0
    let writer = BeadWriter(
        locate: { "/fake/br" },
        runner: { _, _ in
            calls += 1
            // Busy, but not the recovery case: a genuine lock is not this bug.
            return .init(status: 2, standardOutput: "", standardError: "database is busy\n")
        })

    await #expect(throws: BeadWriter.WriteError.self) {
        try await writer.addLabel("ui", to: ["vbx-3"], in: "/tmp/w")
    }
    #expect(calls == 1)
}

@Test("Only a failed run carrying the exact recovery text counts")
func recoveryMatcher() {
    typealias Output = BeadWriter.Output
    #expect(
        BeadWriter.isRecoveryInProgress(
            Output(status: 2, standardOutput: recoveryStdout, standardError: "")))
    #expect(
        BeadWriter.isRecoveryInProgress(
            Output(status: 2, standardOutput: "", standardError: recoveryStderr)))
    // A success that happens to mention it is not a failure to retry.
    #expect(
        !BeadWriter.isRecoveryInProgress(
            Output(status: 0, standardOutput: recoveryStdout, standardError: recoveryStderr)))
    #expect(
        !BeadWriter.isRecoveryInProgress(
            Output(status: 2, standardOutput: "", standardError: "ISSUE_NOT_FOUND")))
}

@MainActor
@Test("Through the real process runner, a stub br failing once with the recovery error is retried")
func recoveryRetryThroughRealProcess() async throws {
    // Exercises `BeadWriter.run` itself — exit status, both pipes — with a stub
    // that behaves like br 0.7.4 minus the 17 s: fail once, then succeed.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vbx-1sw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let stub = dir.appendingPathComponent("br")
    let script = """
        #!/bin/sh
        echo "$@" >> calls
        if [ ! -e failed-once ]; then
          touch failed-once
          echo '{"error":{"code":"DATABASE_ERROR","message":"database is busy (recovery in progress)"}}'
          echo 'ERROR fsqlite_pager::pager: error=database is busy (recovery in progress)' >&2
          exit 2
        fi
        echo '{}'
        """
    try script.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let writer = BeadWriter(locate: { stub.path })
    try await writer.setPriority(3, for: "vbx-6", in: dir.path)

    let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)
    #expect(calls == "update vbx-6 --priority 3 --json\n" + "update vbx-6 --priority 3 --json\n")
}

// MARK: - Which message a failure surfaces (vbx-jmu)

/// The failure `br` 0.7.4 produced in vbx-1sw: its error JSON on stdout and
/// the pager's log on stderr, the one kept line repeated to the 24 it printed.
private let noisyRecoveryStderr = String(repeating: recoveryStderr, count: 24)

/// What the failure message of a run resolves to, through the writer.
@MainActor
private func surfacedMessage(_ output: BeadWriter.Output) async -> String? {
    let writer = BeadWriter(locate: { "/fake/br" }, runner: { _, _ in output })
    do {
        try await writer.setTitle("New", for: "vbx-3", in: "/tmp/w")
    } catch BeadWriter.WriteError.failed(_, let message) {
        return message
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    return nil
}

@MainActor
@Test("br 0.7.4's JSON error is what a failed edit shows, not the pager log on stderr")
func jsonErrorBeatsNoisyStderr() async {
    // The recovery failure is retried once and fails again here; what matters
    // is which stream the second failure is reported from.
    let message = await surfacedMessage(
        .init(status: 2, standardOutput: recoveryStdout, standardError: noisyRecoveryStderr))
    #expect(
        message
            == "Database error: database is busy (recovery in progress) — The WAL index "
            + "(.beads/beads.db-shm) must be rebuilt before br can read the database.")
    #expect(message?.contains("fsqlite_pager") == false)
}

@MainActor
@Test("A JSON error with a null hint shows its message alone")
func jsonErrorWithoutHint() async {
    // Verbatim from br 0.6.0 and 0.7.4 alike, for `update <id> --title "" --json`.
    let stdout = """
        {
          "error": {
            "code": "VALIDATION_FAILED",
            "message": "Validation failed: title: cannot be empty",
            "hint": null,
            "retryable": true,
            "context": {
              "field": "title",
              "reason": "cannot be empty"
            }
          }
        }
        """
    let message = await surfacedMessage(.init(status: 4, standardOutput: stdout, standardError: ""))
    #expect(message == "Validation failed: title: cannot be empty")
}

@Test("The JSON error decodes tolerantly: unknown fields ignored, hint optional")
func structuredErrorIsTolerant() {
    #expect(
        BeadWriter.structuredError(in: #"{"error":{"message":"Issue not found: t-1","new":[1]}}"#)
            == .init(message: "Issue not found: t-1", hint: nil))
    // Not the shape, or no message to show: not a structured error at all.
    #expect(BeadWriter.structuredError(in: #"{"id":"t-1"}"#) == nil)
    #expect(BeadWriter.structuredError(in: #"{"error":{"message":"  "}}"#) == nil)
    #expect(BeadWriter.structuredError(in: "error: unexpected argument '--nope'") == nil)
}

@MainActor
@Test("A failure with no JSON error still shows its stderr")
func plainStderrStillShown() async {
    let message = await surfacedMessage(
        .init(
            status: 2, standardOutput: "",
            standardError: "error: unexpected argument '--nope' found\n"))
    #expect(message == "error: unexpected argument '--nope' found")
}

@MainActor
@Test("A failure with neither JSON nor stderr shows stdout as it is")
func plainStdoutAsLastResort() async {
    let message = await surfacedMessage(
        .init(status: 1, standardOutput: "something broke\n", standardError: ""))
    #expect(message == "something broke")
}
