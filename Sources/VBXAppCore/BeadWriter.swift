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

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                "br was not found. Install it to edit beads from vbx."
            case .failed(let command, let message):
                "\(command) failed: \(message)"
            }
        }
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
    public func setPriority(_ priority: Int, for id: String, in workspace: String) async throws {
        try await run(["update", id, "--priority", String(priority), "--json"], in: workspace)
    }

    /// Sets a bead's title.
    ///
    /// `br` takes the title as one argument, so nothing here quotes or escapes
    /// it: the argument vector goes to `Process` directly, never through a
    /// shell, which is what makes a title containing quotes, `$` or a newline
    /// safe rather than something to sanitise.
    public func setTitle(_ title: String, for id: String, in workspace: String) async throws {
        try await run(Self.titleArguments(title, for: id), in: workspace)
    }

    /// The argument vector for a title change, without running it.
    public static func titleArguments(_ title: String, for id: String) -> [String] {
        ["update", id, "--title", title, "--json"]
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
    public static func priorityArguments(_ priority: Int, for id: String) -> [String] {
        ["update", id, "--priority", String(priority), "--json"]
    }

    private func run(_ arguments: [String], in workspace: String) async throws {
        guard let executable else { throw WriteError.unavailable }
        let output = try await runner([executable] + arguments, workspace)
        guard output.succeeded else {
            let message =
                output.standardError.isEmpty
                ? output.standardOutput : output.standardError
            throw WriteError.failed(
                command: "br " + arguments.joined(separator: " "),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Finds `br` on disk.
    ///
    /// `PATH` is searched, but a GUI app launched from Finder inherits a
    /// minimal one that usually holds none of the places a developer installs
    /// tools — so the common install locations are checked too. Without that,
    /// editing would work from a terminal launch and mysteriously not from the
    /// Dock.
    public static func locateBR() -> String? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/br" }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.cargo/bin/br",
            "/opt/homebrew/bin/br",
            "/usr/local/bin/br",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
