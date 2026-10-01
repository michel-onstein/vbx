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

// MARK: - Guarded single-bead edits: br update --if-unchanged (vbx-7fh)

/// The line `br` 0.7.4's `update --help` carries for the flag, trimmed.
private let helpWithGuard = """
    Update an issue

    Usage: br update [OPTIONS] [IDS]...

          --if-unchanged <UPDATED_AT>
              Only apply this update if the issue has not changed since you read it (GitHub #500).
    """
/// `br` 0.6.0's `update --help`: no such option.
private let helpWithoutGuard = """
    Update an issue

    Usage: br update [OPTIONS] [IDS]...

          --priority <PRIORITY>
    """

/// What `br` 0.7.4 printed, verbatim, for a guarded update whose stamp was
/// stale — exit 6, nothing written. Captured 2026-10-01.
private let preconditionStdout = """
    {
      "error": {
        "code": "UPDATE_PRECONDITION_FAILED",
        "message": "vbx-3 changed since you read it: expected updated_at 2026-01-01T00:00:00Z, \
    found 2026-08-10T12:00:00Z. Nothing was written — re-read the issue and reapply your edit \
    to the current value.",
        "hint": "Re-read it (`br show vbx-3 --json`), reapply your edit to the current value, \
    and retry with the new --if-unchanged token.",
        "retryable": true,
        "context": {
          "issue_id": "vbx-3",
          "expected_updated_at": "2026-01-01T00:00:00Z",
          "actual_updated_at": "2026-08-10T12:00:00Z",
          "written": false
        }
      }
    }
    """

private let stamp = "2026-10-01T22:33:13.885481Z"

/// A fake `br` that answers `update --help` with `help` and every other
/// command through `respond`, recording everything it was sent.
@MainActor
private final class FakeBR {
    var sent: [[String]] = []
    let help: String
    var respond: (_ argv: [String], _ call: Int) -> BeadWriter.Output

    init(
        help: String = helpWithGuard,
        respond: @escaping (_ argv: [String], _ call: Int) -> BeadWriter.Output = { _, _ in
            .init(status: 0, standardOutput: "[]", standardError: "")
        }
    ) {
        self.help = help
        self.respond = respond
    }

    /// The writes and reads sent, without the help probe.
    var commands: [[String]] { sent.filter { $0 != ["/fake/br", "update", "--help"] } }
    var probes: Int { sent.count - commands.count }

    func writer() -> BeadWriter {
        BeadWriter(
            locate: { "/fake/br" },
            runner: { [self] argv, _ in
                sent.append(argv)
                if argv == ["/fake/br", "update", "--help"] {
                    return .init(status: 0, standardOutput: help, standardError: "")
                }
                return respond(argv, commands.count)
            })
    }
}

@MainActor
@Test("The guard goes between the edit and --json, title and priority alike")
func guardedArgumentsArePinned() {
    #expect(
        BeadWriter.priorityArguments(2, for: "vbx-3", ifUnchangedSince: stamp)
            == ["update", "vbx-3", "--priority", "2", "--if-unchanged", stamp, "--json"])
    #expect(
        BeadWriter.titleArguments("New", for: "vbx-3", ifUnchangedSince: stamp)
            == ["update", "vbx-3", "--title", "New", "--if-unchanged", stamp, "--json"])
    // No stamp: exactly the command vbx always sent.
    #expect(BeadWriter.priorityArguments(2, for: "vbx-3") == ["update", "vbx-3", "--priority", "2", "--json"])
}

@MainActor
@Test("A br that has --if-unchanged gets the displayed record's updated_at with the edit")
func guardIsSentWhenSupported() async throws {
    let br = FakeBR()
    let writer = br.writer()

    try await writer.setPriority(2, for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)
    try await writer.setTitle("New", for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)

    #expect(
        br.commands == [
            ["/fake/br"] + BeadWriter.priorityArguments(2, for: "vbx-3", ifUnchangedSince: stamp),
            ["/fake/br"] + BeadWriter.titleArguments("New", for: "vbx-3", ifUnchangedSince: stamp),
        ])
    // Asked once, then remembered for the writer's life.
    #expect(br.probes == 1)
}

@MainActor
@Test("br 0.6.0, without --if-unchanged, gets the unguarded write it always did")
func olderBRFallsBackToUnguardedWrite() async throws {
    let br = FakeBR(help: helpWithoutGuard)
    let writer = br.writer()

    try await writer.setPriority(2, for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)

    // Sending the flag anyway would fail every edit with "unexpected argument".
    #expect(br.commands == [["/fake/br"] + BeadWriter.priorityArguments(2, for: "vbx-3")])
}

@MainActor
@Test("With no stamp to guard with, br is not even asked whether it could")
func noStampNoProbe() async throws {
    let br = FakeBR()
    try await br.writer().setPriority(2, for: "vbx-3", in: "/tmp/w")
    #expect(br.probes == 0)
    #expect(br.commands == [["/fake/br"] + BeadWriter.priorityArguments(2, for: "vbx-3")])
}

@MainActor
@Test("A refused guard is a conflict, reported at once, with nothing retried")
func preconditionFailureIsAConflict() async {
    let br = FakeBR { _, _ in
        .init(status: 6, standardOutput: preconditionStdout, standardError: "")
    }
    let writer = br.writer()

    do {
        try await writer.setTitle("New", for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)
        Issue.record("a refused write was reported as success")
    } catch BeadWriter.WriteError.changedSinceRead(let id) {
        #expect(id == "vbx-3")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    // A first-attempt refusal cannot be vbx's own write, so no `br show`.
    #expect(br.commands.count == 1)
    let message = BeadWriter.WriteError.changedSinceRead(id: "vbx-3").errorDescription
    #expect(message?.contains("vbx-3 was changed elsewhere") == true)
    #expect(message?.contains("not written") == true)
}

@Test("Only br's UPDATE_PRECONDITION_FAILED code counts as a refused guard")
func preconditionMatcher() {
    typealias Output = BeadWriter.Output
    #expect(BeadWriter.isPreconditionFailure(Output(status: 6, standardOutput: preconditionStdout, standardError: "")))
    #expect(!BeadWriter.isPreconditionFailure(Output(status: 2, standardOutput: recoveryStdout, standardError: "")))
    #expect(!BeadWriter.isPreconditionFailure(Output(status: 0, standardOutput: preconditionStdout, standardError: "")))
}

/// `br show <id> --json` for vbx-3, as br answers it: an array of one record.
private func shown(priority: Int, title: String = "Wire the engine") -> BeadWriter.Output {
    .init(
        status: 0,
        standardOutput: #"[{"id":"vbx-3","title":"\#(title)","priority":\#(priority),"updated_at":"2026-10-01T22:33:18.542480Z"}]"#,
        standardError: "")
}

@MainActor
@Test("A retried guarded write whose first attempt landed is a success, not a conflict")
func retryAfterLandedFirstAttemptSucceeds() async throws {
    // The first attempt fails with "recovery in progress" but its write lands,
    // moving updated_at; the retry carries the same stamp and is refused. The
    // record already says what the edit wanted, so the edit is done.
    let br = FakeBR { argv, call in
        switch call {
        case 1: .init(status: 2, standardOutput: recoveryStdout, standardError: recoveryStderr)
        case 2: .init(status: 6, standardOutput: preconditionStdout, standardError: "")
        default: argv.contains("show") ? shown(priority: 2) : .init(status: 1, standardOutput: "", standardError: "?")
        }
    }

    try await br.writer().setPriority(2, for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)

    let update = ["/fake/br"] + BeadWriter.priorityArguments(2, for: "vbx-3", ifUnchangedSince: stamp)
    // The retry is guarded exactly as the first attempt was.
    #expect(br.commands == [update, update, ["/fake/br", "show", "vbx-3", "--json"]])
}

@MainActor
@Test("A retried guarded title whose first attempt landed is a success too")
func retryAfterLandedTitleSucceeds() async throws {
    let br = FakeBR { argv, call in
        switch call {
        case 1: .init(status: 2, standardOutput: recoveryStdout, standardError: recoveryStderr)
        case 2: .init(status: 6, standardOutput: preconditionStdout, standardError: "")
        default: shown(priority: 1, title: "Renamed")
        }
    }
    try await br.writer().setTitle("Renamed", for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)
}

@MainActor
@Test("A retried guarded write refused over someone else's change is still a conflict")
func retryRefusedByAnotherWriterIsAConflict() async {
    // Same sequence, but the record says something else: the first attempt did
    // not land, another writer moved the record, and the edit must not pass.
    let br = FakeBR { _, call in
        switch call {
        case 1: .init(status: 2, standardOutput: recoveryStdout, standardError: recoveryStderr)
        case 2: .init(status: 6, standardOutput: preconditionStdout, standardError: "")
        default: shown(priority: 4)
        }
    }
    do {
        try await br.writer().setPriority(2, for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)
        Issue.record("a write refused over another writer's change was reported as success")
    } catch BeadWriter.WriteError.changedSinceRead(let id) {
        #expect(id == "vbx-3")
    } catch {
        Issue.record("expected changedSinceRead, got \(error)")
    }
}

@MainActor
@Test("A retried refusal whose record cannot be read back is a conflict, not a guess")
func retryWithUnreadableRecordIsAConflict() async {
    let br = FakeBR { _, call in
        switch call {
        case 1: .init(status: 2, standardOutput: recoveryStdout, standardError: recoveryStderr)
        case 2: .init(status: 6, standardOutput: preconditionStdout, standardError: "")
        default: .init(status: 3, standardOutput: "", standardError: "no such issue")
        }
    }
    await #expect(throws: BeadWriter.WriteError.self) {
        try await br.writer().setPriority(2, for: "vbx-3", in: "/tmp/w", ifUnchangedSince: stamp)
    }
}

@Test("br show's array answer decodes to its first record")
func shownRecordDecodes() {
    #expect(
        BeadWriter.shownRecord(in: #"[{"id":"t-1","title":"T","priority":3,"labels":["x"]}]"#)
            == .init(title: "T", priority: 3))
    #expect(BeadWriter.shownRecord(in: "[]") == nil)
    #expect(BeadWriter.shownRecord(in: #"{"error":{"message":"nope"}}"#) == nil)
}

@MainActor
@Test("Through the real process runner, a stub br 0.7 refuses a stale stamp and vbx reports a conflict")
func guardThroughRealProcess() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vbx-7fh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Behaves like br 0.7.4 for the two commands vbx sends: advertises the
    // flag, and refuses any stamp but the current one with exit 6.
    let stub = dir.appendingPathComponent("br")
    let script = """
        #!/bin/sh
        echo "$@" >> calls
        if [ "$1 $2" = "update --help" ]; then
          echo '      --if-unchanged <UPDATED_AT>'
          exit 0
        fi
        if [ "$5" = "--if-unchanged" ] && [ "$6" != "2026-10-01T22:33:13.885481Z" ]; then
          echo '{"error":{"code":"UPDATE_PRECONDITION_FAILED","message":"changed since you read it"}}'
          exit 6
        fi
        echo '[]'
        """
    try script.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let writer = BeadWriter(locate: { stub.path })
    try await writer.setPriority(3, for: "vbx-6", in: dir.path, ifUnchangedSince: stamp)
    await #expect(throws: BeadWriter.WriteError.self) {
        try await writer.setPriority(3, for: "vbx-6", in: dir.path, ifUnchangedSince: "2026-10-01T22:33:13.885Z")
    }

    let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)
    #expect(
        calls
            == "update --help\n"
            + "update vbx-6 --priority 3 --if-unchanged \(stamp) --json\n"
            + "update vbx-6 --priority 3 --if-unchanged 2026-10-01T22:33:13.885Z --json\n")
}

// MARK: - The store's side of a conflict

@MainActor
@Test("A conflicting title edit reloads and says why, and passed the displayed updated_at")
func storeConflictReloadsAndExplains() async throws {
    let store = ProjectStore()
    store.skipPhase2 = true
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo").path
    await store.open(path: fixture)
    defer { Task { await store.close() } }

    let bead = try #require(store.issues.first { !$0.status.isImmutable })
    let displayed = try #require(bead.updatedAtStamp)

    let br = FakeBR { _, _ in
        .init(status: 6, standardOutput: preconditionStdout, standardError: "")
    }
    store.writer = br.writer()
    let reloadedBefore = store.lastReloadAt

    let wrote = await store.setTitle(bead.title + " (renamed)", for: bead.id)

    #expect(!wrote)
    #expect(
        br.commands == [
            ["/fake/br"]
                + BeadWriter.titleArguments(
                    bead.title + " (renamed)", for: bead.id, ifUnchangedSince: displayed)
        ])
    #expect(store.loadError == BeadWriter.WriteError.changedSinceRead(id: bead.id).errorDescription)
    // Reloaded, so what is on screen is the newer record the message refers to.
    #expect(store.lastReloadAt != nil && store.lastReloadAt != reloadedBefore)
}

@MainActor
@Test("Each bead of a multi-bead priority change is guarded by its own updated_at")
func storeGuardsEachBeadOfASelection() async throws {
    let store = ProjectStore()
    store.skipPhase2 = true
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo").path
    await store.open(path: fixture)
    defer { Task { await store.close() } }

    let beads = Array(store.issues.filter { !$0.status.isImmutable }.prefix(2))
    try #require(beads.count == 2)
    let br = FakeBR()
    store.writer = br.writer()

    let failed = await store.setPriority(4, for: Set(beads.map(\.id)))

    #expect(failed.isEmpty)
    let expected = beads.sorted { $0.id < $1.id }.map {
        ["/fake/br"] + BeadWriter.priorityArguments(4, for: $0.id, ifUnchangedSince: $0.updatedAtStamp)
    }
    #expect(br.commands == expected)
}
