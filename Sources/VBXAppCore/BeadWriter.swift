import Foundation

/// Writes bead changes, by asking `br` to make them.
///
/// ## Why not write the file
///
/// `.beads/issues.jsonl` is a **whole-file export** of `.beads/beads.db`. The
/// database is gitignored, so there is one per checkout and every worktree
/// carries its own. A flush from a database that predates someone else's
/// changes rewrites the entire file and drops them — and because git sees a
/// rewrite rather than overlapping hunks, there is no conflict and no error.
/// Last flush wins, silently.
///
/// An app that serialised its in-memory bead set back to that file would be
/// exactly that stale flush, in a GUI, one double-click away. So `br` owns the
/// database and the export, and vbx composes commands for it.
@MainActor
public final class BeadWriter: ObservableObject {

    /// What running a command produced.
    public struct Output: Sendable {
        public let status: Int32
        public let standardOutput: String
        public let standardError: String
        public var succeeded: Bool { status == 0 }
    }

    public enum WriteError: LocalizedError {
        case unavailable
        case failed(command: String, message: String)
        /// The bead moved on since vbx read it, so `br` wrote nothing.
        ///
        /// `br update --if-unchanged` refused the edit: some other writer — an
        /// agent, a terminal — changed the record after vbx displayed it.
        /// Distinct from ``failed(command:message:)`` because the caller's
        /// answer differs: reload, so the user sees the newer record and
        /// decides whether the edit still applies.
        case changedSinceRead(id: String)

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                "br was not found. Install it to edit beads from vbx."
            case .failed(let command, let message):
                "\(command) failed: \(message)"
            case .changedSinceRead(let id):
                "\(id) was changed elsewhere after vbx showed it, so your edit was not "
                    + "written. The current version is now shown — make the edit again "
                    + "if it still applies."
            }
        }
    }

    /// A single-bead edit, as what the record should say once it has landed.
    ///
    /// Only needed for the one case where vbx has to ask: a guarded write that
    /// was retried and then refused, which is what a first attempt that landed
    /// looks like from the outside.
    enum Edit: Equatable {
        case priority(Int)
        case title(String)

        func isApplied(to record: ShownRecord) -> Bool {
            switch self {
            case .priority(let priority): record.priority == priority
            case .title(let title): record.title == title
            }
        }
    }

    /// The fields of `br show <id> --json` an ``Edit`` is checked against.
    struct ShownRecord: Decodable, Equatable {
        var title: String?
        var priority: Int?
    }

    /// Runs an argument vector and reports what happened.
    ///
    /// Injected so tests can assert the exact command without `br` installed,
    /// and without writing to a real workspace.
    public typealias Runner = @MainActor ([String], String) async throws -> Output

    private let runner: Runner
    private let locate: () -> String?

    /// Where `br` is, if it is anywhere.
    public private(set) lazy var executable: String? = locate()

    /// False when `br` is missing, which is a normal state rather than an
    /// error: the app stays a viewer and says so.
    public var isAvailable: Bool { executable != nil }

    public init(
        locate: @escaping () -> String? = BeadWriter.locateBR,
        runner: @escaping Runner = BeadWriter.run
    ) {
        self.locate = locate
        self.runner = runner
    }

    /// Sets a bead's priority.
    ///
    /// Returns once `br` has written; the caller reloads, because the file on
    /// disk is the source of truth and the in-memory copy is now stale.
    ///
    /// `stamp` is the `updated_at` of the record vbx displayed
    /// (``Issue/updatedAtStamp``). When the installed `br` supports
    /// `--if-unchanged` it guards the write, and a record that has moved on
    /// throws ``WriteError/changedSinceRead(id:)`` with nothing written.
    public func setPriority(
        _ priority: Int, for id: String, in workspace: String,
        ifUnchangedSince stamp: String? = nil
    ) async throws {
        let guardStamp = await guardStamp(stamp, in: workspace)
        try await run(
            Self.priorityArguments(priority, for: id, ifUnchangedSince: guardStamp),
            in: workspace, guarding: guardStamp.map { _ in (id, .priority(priority)) })
    }

    /// Sets a bead's title.
    ///
    /// `br` takes the title as one argument, so nothing here quotes or escapes
    /// it: the argument vector goes to `Process` directly, never through a
    /// shell, which is what makes a title containing quotes, `$` or a newline
    /// safe rather than something to sanitise. `stamp` guards the write as
    /// for ``setPriority(_:for:in:ifUnchangedSince:)``.
    public func setTitle(
        _ title: String, for id: String, in workspace: String,
        ifUnchangedSince stamp: String? = nil
    ) async throws {
        let guardStamp = await guardStamp(stamp, in: workspace)
        try await run(
            Self.titleArguments(title, for: id, ifUnchangedSince: guardStamp),
            in: workspace, guarding: guardStamp.map { _ in (id, .title(title)) })
    }

    /// The argument vector for a title change, without running it.
    public static func titleArguments(
        _ title: String, for id: String, ifUnchangedSince stamp: String? = nil
    ) -> [String] {
        ["update", id, "--title", title] + ifUnchangedArguments(stamp) + ["--json"]
    }

    /// `--if-unchanged <stamp>`, or nothing when there is no stamp to send.
    private static func ifUnchangedArguments(_ stamp: String?) -> [String] {
        stamp.map { ["--if-unchanged", $0] } ?? []
    }

    // MARK: - Guarded writes (br >= 0.7.0)

    /// Whether the installed `br` takes `--if-unchanged`, once known.
    ///
    /// `br` 0.7.0 added it; 0.6.0 rejects it as an unexpected argument, which
    /// would fail every edit. So it is detected rather than assumed, by asking
    /// `br update --help` — the feature itself, not a version number that a
    /// fork or a pre-release could get wrong. Cached for the writer's life,
    /// since the executable is too; an inconclusive probe is not cached.
    private var ifUnchangedSupport: Bool?

    /// Whether `--if-unchanged` can be sent to this `br`.
    func supportsIfUnchanged(in workspace: String) async -> Bool {
        if let ifUnchangedSupport { return ifUnchangedSupport }
        guard let executable,
            let help = try? await runner([executable, "update", "--help"], workspace),
            help.succeeded
        else { return false }
        let supported = help.standardOutput.contains("--if-unchanged")
        ifUnchangedSupport = supported
        return supported
    }

    /// The stamp to guard with: `stamp` when `br` can take it, else none, so
    /// an older `br` gets the unguarded write it always did.
    private func guardStamp(_ stamp: String?, in workspace: String) async -> String? {
        guard let stamp, !stamp.isEmpty else { return nil }
        return await supportsIfUnchanged(in: workspace) ? stamp : nil
    }

    /// Whether a run is `br` refusing a guarded write because the record moved.
    ///
    /// `br` 0.7 exits 6 with `UPDATE_PRECONDITION_FAILED` as the JSON error's
    /// `code`, and writes nothing. Matched on the code, which names the
    /// failure, rather than on an exit status other failures could share.
    nonisolated static func isPreconditionFailure(_ output: Output) -> Bool {
        !output.succeeded
            && structuredError(in: output.standardOutput)?.code == preconditionFailedCode
    }

    nonisolated static let preconditionFailedCode = "UPDATE_PRECONDITION_FAILED"

    /// The record as `br` has it now, for checking whether an edit landed.
    private func currentRecord(_ id: String, in workspace: String) async -> ShownRecord? {
        guard let executable,
            let output = try? await runner([executable, "show", id, "--json"], workspace),
            output.succeeded
        else { return nil }
        return Self.shownRecord(in: output.standardOutput)
    }

    /// The first record of `br show --json`, which answers with an array.
    nonisolated static func shownRecord(in standardOutput: String) -> ShownRecord? {
        guard let data = standardOutput.data(using: .utf8),
            let records = try? JSONDecoder().decode([ShownRecord].self, from: data)
        else { return nil }
        return records.first
    }

    /// Adds a label to every bead in `ids`.
    ///
    /// One invocation for the whole selection: `br label add` takes several
    /// issues, so this is one process and one write rather than a loop that can
    /// half-succeed.
    public func addLabel(
        _ label: String, to ids: [String], in workspace: String
    ) async throws {
        try await run(Self.addLabelArguments(label, to: ids), in: workspace)
    }

    /// Removes a label from every bead in `ids`.
    public func removeLabel(
        _ label: String, from ids: [String], in workspace: String
    ) async throws {
        try await run(Self.removeLabelArguments(label, from: ids), in: workspace)
    }

    /// The argument vector for adding a label, without running it.
    ///
    /// Note the shape: the issue ids are **positional** and the label is an
    /// option, which is the reverse of `update`. Pinned by a test for exactly
    /// that reason — getting it backwards would label an issue named after the
    /// label, or fail in a way that reads like `br` being broken.
    public static func addLabelArguments(_ label: String, to ids: [String]) -> [String] {
        ["label", "add"] + ids.sorted() + ["--label", label, "--json"]
    }

    /// The argument vector for removing a label, without running it.
    public static func removeLabelArguments(_ label: String, from ids: [String]) -> [String] {
        ["label", "remove"] + ids.sorted() + ["--label", label, "--json"]
    }

    /// The argument vector for a priority change, without running it.
    ///
    /// Exposed so a test can pin the command rather than a mock's idea of it —
    /// the flags are the contract with `br`, and a typo in one is a silent
    /// no-op or, worse, a different edit.
    public static func priorityArguments(
        _ priority: Int, for id: String, ifUnchangedSince stamp: String? = nil
    ) -> [String] {
        ["update", id, "--priority", String(priority)] + ifUnchangedArguments(stamp) + ["--json"]
    }

    /// Runs one write, retrying `br` 0.7.4's transient recovery failure.
    ///
    /// `guarding` names the bead and the edit when the arguments carry
    /// `--if-unchanged`. The retry re-sends the *same* arguments, stamp and
    /// all, so it is guarded exactly as the first attempt was. That has one
    /// consequence to handle: if the first attempt actually landed before
    /// failing, the record's `updated_at` has moved — by vbx's own write — and
    /// the retry is refused. So a refusal *after a retry* asks `br` what the
    /// record says now, and when it already says what this edit would make it
    /// say, the edit is done. A refusal on the first attempt is always a
    /// conflict: nothing of vbx's can have moved the record yet.
    private func run(
        _ arguments: [String], in workspace: String,
        guarding: (id: String, edit: Edit)? = nil
    ) async throws {
        guard let executable else { throw WriteError.unavailable }
        var output = try await runner([executable] + arguments, workspace)
        var retried = false
        if Self.isRecoveryInProgress(output) {
            // One retry, and only one: the failed attempt is what finishes the
            // recovery, so a second failure is a real problem worth showing.
            output = try await runner([executable] + arguments, workspace)
            retried = true
        }
        if let guarding, Self.isPreconditionFailure(output) {
            if retried, let record = await currentRecord(guarding.id, in: workspace),
                guarding.edit.isApplied(to: record)
            {
                return
            }
            throw WriteError.changedSinceRead(id: guarding.id)
        }
        guard output.succeeded else {
            throw WriteError.failed(
                command: "br " + arguments.joined(separator: " "),
                message: Self.failureMessage(output))
        }
    }

    /// What to tell the user about a failed run.
    ///
    /// `br` answers a `--json` command that fails with a structured error on
    /// **stdout** — `{"error":{"code","message","hint",…}}`, from 0.6.0 and
    /// 0.7.4 alike — and that is the message meant for a person. Stderr is
    /// not: `br` 0.7.4 writes its tracing log there, so a failed write can
    /// carry two dozen `ERROR fsqlite_pager::pager: …` lines that say nothing
    /// about what went wrong. So the JSON's `message` (and `hint`, when there
    /// is one) wins whenever it parses; otherwise stderr, which is where
    /// argument errors and anything pre-JSON go; otherwise stdout as it is.
    nonisolated static func failureMessage(_ output: Output) -> String {
        if let error = structuredError(in: output.standardOutput) {
            guard let hint = error.hint?.trimmingCharacters(in: .whitespacesAndNewlines),
                !hint.isEmpty
            else { return error.message }
            return "\(error.message) — \(hint)"
        }
        let error = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty
            ? output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : error
    }

    /// The `error` object of `br`'s JSON failure, when stdout holds one.
    ///
    /// Decoded tolerantly: only `message` is required, every other field —
    /// `code`, `retryable`, `context`, whatever a later `br` adds — is
    /// ignored, and a `hint` that is absent or `null` is simply no hint.
    nonisolated static func structuredError(in standardOutput: String) -> StructuredError? {
        guard let data = standardOutput.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        else { return nil }
        let message = envelope.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        return StructuredError(
            message: message, hint: envelope.error.hint, code: envelope.error.code)
    }

    /// The part of `br`'s JSON error a person needs, and the code that tells
    /// vbx which failure it is.
    struct StructuredError: Decodable, Equatable {
        let message: String
        let hint: String?
        var code: String? = nil
    }

    private struct ErrorEnvelope: Decodable {
        let error: StructuredError
    }

    /// The text `br` 0.7.4 fails with on the first write after a stock SQLite
    /// reader has opened `beads.db`.
    static let recoveryInProgress = "database is busy (recovery in progress)"

    /// Whether a failed run is `br` 0.7.4's transient "recovery in progress".
    ///
    /// Once any ordinary SQLite client (`bv`, `sqlite3`) has opened the
    /// database, the next `br` 0.7.4 write retries for about 17 s and exits 2
    /// with `DATABASE_ERROR` — the error JSON on stdout, the retry log on
    /// stderr — and the write after it succeeds. `br` 0.6.0 does not do this.
    /// Every edit vbx sends is idempotent (set a priority, set a title, add or
    /// remove a label), so re-sending it is safe whether or not the failed
    /// attempt landed — except that a guarded write (`--if-unchanged`) whose
    /// first attempt landed is then refused, which ``run(_:in:guarding:)``
    /// recognises. Matched on the exact text and a non-zero exit, so no other
    /// failure is retried.
    nonisolated static func isRecoveryInProgress(_ output: Output) -> Bool {
        !output.succeeded
            && (output.standardOutput.contains(recoveryInProgress)
                || output.standardError.contains(recoveryInProgress))
    }

    /// Finds `br` on disk.
    ///
    /// `PATH` is searched, but a GUI app launched from Finder inherits a
    /// minimal one that usually holds none of the places a developer installs
    /// tools — so the common install locations are checked too. Without that,
    /// editing would work from a terminal launch and mysteriously not from the
    /// Dock.
    public static func locateBR() -> String? {
        let candidates = brCandidates(
            path: ProcessInfo.processInfo.environment["PATH"],
            home: FileManager.default.homeDirectoryForCurrentUser.path)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every place ``locateBR()`` looks, in the order it looks.
    ///
    /// `PATH` first, so a terminal launch uses whichever `br` the shell would.
    /// Then the install locations a Finder launch cannot see: `~/.local/bin`
    /// (br's own installer), `~/.cargo/bin` (`cargo install`), and Homebrew on
    /// Apple silicon and Intel. Separate from the probe so a test can pin the
    /// list without depending on what is installed.
    public static func brCandidates(path: String?, home: String) -> [String] {
        var candidates: [String] = []
        if let path {
            candidates += path.split(separator: ":").map { "\($0)/br" }
        }
        candidates += [
            "\(home)/.local/bin/br",
            "\(home)/.cargo/bin/br",
            "/opt/homebrew/bin/br",
            "/usr/local/bin/br",
        ]
        return candidates
    }

    /// Runs a command in the workspace directory.
    public static func run(_ argv: [String], in workspace: String) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self))
    }
}
