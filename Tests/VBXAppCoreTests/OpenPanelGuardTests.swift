import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// The Open panel's folder guard.
///
/// Every case here is driven through the real engine probe rather than a stub,
/// because the property worth protecting is not "the guard returns what it was
/// told" — it is that the guard and the loader agree.
@Suite("Open panel guard")
struct OpenPanelGuardTests {

    private var demoFixture: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo")
            .path
    }

    @Test("A folder holding .beads is offered")
    func acceptsWorkspaceFolder() {
        let guardDelegate = OpenPanelGuard()

        #expect(guardDelegate.canOpen(demoFixture))
        #expect(guardDelegate.panel(NSNull(), shouldEnable: URL(fileURLWithPath: demoFixture)))
    }

    @Test("The .beads directory itself is offered")
    func acceptsBeadsDirectory() {
        let path = URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads").path
        #expect(OpenPanelGuard().canOpen(path))
    }

    @Test("A bead data file is offered")
    func acceptsDataFile() throws {
        let beads = URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads")
        let file = try #require(
            try FileManager.default.contentsOfDirectory(atPath: beads.path)
                .first { $0.hasSuffix(".jsonl") })

        #expect(OpenPanelGuard().canOpen(beads.appendingPathComponent(file).path))
    }

    @Test("A workspace root whose .beads live in the repositories below it is offered")
    func acceptsMultiRepoRoot() throws {
        // The case the literal "must contain .beads" rule breaks. A root
        // configured this way holds no .beads of its own, and refusing it
        // would make multi-repository workspaces unreachable from the panel.
        let root = try Self.temporaryDirectory()
        let config = root.appendingPathComponent(".bv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
            repos:
              - path: alpha
            """.write(
            to: config.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

        let guardDelegate = OpenPanelGuard()

        #expect(guardDelegate.canOpen(root.path))
        #expect(guardDelegate.result(for: root.path).kind == "workspace")
    }

    @Test("A folder with its own .beads under a workspace offers the repository; the yaml offers the aggregate")
    func bothOffersTheRepositoryAndTheConfigOffersTheAggregate() throws {
        // bv's precedence (ADR-026): the folder's own `.beads` wins, and the
        // aggregate is reached by choosing the configuration file itself.
        let root = try Self.temporaryDirectory()
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads"),
            to: root.appendingPathComponent(".beads"))
        let config = root.appendingPathComponent(".bv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let yaml = config.appendingPathComponent("workspace.yaml")
        try """
            repos:
              - path: alpha
            """.write(to: yaml, atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("notes.yaml")
        try "title: not a workspace\n".write(to: other, atomically: true, encoding: .utf8)

        let guardDelegate = OpenPanelGuard()

        #expect(guardDelegate.result(for: root.path).kind == "jsonl")
        #expect(guardDelegate.canOpen(yaml.path))
        #expect(guardDelegate.result(for: yaml.path).kind == "workspace")
        #expect(!guardDelegate.canOpen(other.path))
    }

    @Test("A folder with no bead data is refused, with a reason")
    func refusesEmptyFolder() throws {
        let empty = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        #expect(!guardDelegate.canOpen(empty.path))
        // Deliberately *not* asserting that the row is greyed. It used to be,
        // and that is what made the panel impossible to navigate: a disabled
        // directory cannot be entered, so every folder on the way to a
        // repository was a dead end. The refusal now happens on OK instead —
        // see `unopenableFolderStaysNavigable` and the validate test below.
        //
        // An unexplained refusal is the thing users file bugs about, so it
        // still has to carry a reason.
        #expect(!guardDelegate.result(for: empty.path).reason.isEmpty)
        #expect(guardDelegate.refusal(for: empty.path).contains(empty.lastPathComponent))
    }

    @Test("Validation is the gate, not the greying")
    func validationRefuses() throws {
        let empty = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        // shouldEnable only greys the row; a path typed into Go-to-folder never
        // passes through it. Validation is what actually stops the open.
        #expect(throws: (any Error).self) {
            try guardDelegate.panel(NSNull(), validate: empty)
        }
        try guardDelegate.panel(NSNull(), validate: URL(fileURLWithPath: demoFixture))
    }

    @Test("A path that does not exist is refused rather than crashing")
    func refusesMissingPath() throws {
        let missing = try Self.temporaryDirectory().appendingPathComponent("nowhere")
        #expect(!OpenPanelGuard().canOpen(missing.path))
    }

    @Test("Repeated questions about one folder are answered once")
    func cachesAnswers() {
        var asked = 0
        let guardDelegate = OpenPanelGuard { path in
            asked += 1
            return ProbeResult(path: path, canOpen: true, kind: "jsonl")
        }

        // The panel asks about every visible row on every redraw; without the
        // cache, scrolling a large folder would re-probe on each frame.
        for _ in 0..<50 { _ = guardDelegate.canOpen("/some/path") }

        #expect(asked == 1)
    }

    @Test("What the guard offers, the store can actually open")
    func agreesWithTheStore() async {
        // The invariant the whole design exists for. A guard that says yes and
        // a store that then fails is worse than no guard at all.
        let guardDelegate = OpenPanelGuard()
        #expect(guardDelegate.canOpen(demoFixture))

        let store = await ProjectStore()
        await store.open(path: demoFixture)
        let failed = await store.loadError

        #expect(failed == nil)
        await store.close()
    }

    @Test("What the guard refuses, the store would have failed to open")
    func refusalMatchesTheStore() async throws {
        let empty = try Self.temporaryDirectory()
        #expect(!OpenPanelGuard().canOpen(empty.path))

        let store = await ProjectStore()
        await store.open(path: empty.path)
        let failed = await store.loadError

        #expect(failed != nil)
        await store.close()
    }

    @Test("A folder that cannot be opened is still enabled, so it can be entered")
    func unopenableFolderStaysNavigable() throws {
        // The bug this guards: greying an unopenable directory also stops it
        // being double-clicked, and every folder on the way to a repository is
        // itself unopenable. `~/src` holds no .beads, so the panel could not be
        // navigated down to a workspace at all unless it opened inside one.
        let plain = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        #expect(!guardDelegate.canOpen(plain.path), "premise: this folder cannot be opened")
        #expect(
            guardDelegate.panel(NSNull(), shouldEnable: plain),
            "an unopenable folder must stay enabled or it cannot be entered")
    }

    @Test("An unopenable folder is still refused on OK, with a reason")
    func unopenableFolderIsRefusedOnValidate() throws {
        // The other half, and the reason enabling the row costs nothing:
        // validate is the actual gate. Without this the fix above would read
        // as "the guard stopped guarding".
        let plain = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        #expect(throws: (any Error).self) {
            try guardDelegate.panel(NSNull(), validate: plain)
        }
        #expect(guardDelegate.refusal(for: plain.path).contains("cannot be opened"))
    }

    @Test("A file that is not bead data is greyed out")
    func nonBeadFileIsDisabled() throws {
        // Files are still greyed, and this is where the greying does work.
        // `resolveSource` used to treat every non-.db file as JSONL, so a
        // README — or a binary — reported openable and nothing was greyed.
        let directory = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        for name in ["README.md", "notes", "icon.icns"] {
            let file = directory.appendingPathComponent(name)
            try Data("not bead data\n".utf8).write(to: file)

            #expect(!guardDelegate.canOpen(file.path), "\(name) reported openable")
            #expect(
                !guardDelegate.panel(NSNull(), shouldEnable: file),
                "\(name) was offered in the panel")
        }
    }

    @Test("A .jsonl file is still offered")
    func beadDataFileStaysEnabled() throws {
        // Guards the over-correction: refusing every file would switch the
        // panel's file support off entirely, and the engine genuinely opens a
        // data file chosen directly.
        let beads = URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads")
        let file = beads.appendingPathComponent("issues.jsonl")
        let guardDelegate = OpenPanelGuard()

        #expect(guardDelegate.canOpen(file.path))
        #expect(guardDelegate.panel(NSNull(), shouldEnable: file))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vbx-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
