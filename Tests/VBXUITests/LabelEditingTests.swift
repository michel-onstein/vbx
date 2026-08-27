import AppKit
import VBXAppCore
import VBXCore
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// Editing a bead's labels from the Labels cell.
///
/// The write goes through `br label add` / `remove`, which takes the issue ids
/// **positionally** and the label as an option — the reverse of `update`, and
/// the reason the argument vectors are pinned here.
@MainActor
@Suite("Label editing")
struct LabelEditingTests {

    @Test("The argument vectors match br's shape")
    func argumentVectorsArePinned() {
        // Pinned rather than mocked: the flags are the contract with `br`, and
        // getting the shape backwards would label an issue named after the
        // label, or fail in a way that reads like `br` being broken.
        #expect(
            BeadWriter.addLabelArguments("backend", to: ["vbx-2", "vbx-1"])
                == ["label", "add", "vbx-1", "vbx-2", "--label", "backend", "--json"])
        #expect(
            BeadWriter.removeLabelArguments("ui", from: ["vbx-1"])
                == ["label", "remove", "vbx-1", "--label", "ui", "--json"])
    }

    @Test("A label is added and removed through br")
    func labelsRoundTrip() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let target = try #require(store.issues.first(where: { !$0.status.isImmutable })?.id)

        let added = await store.setLabel("vbx-dot-test", on: [target], present: true)
        #expect(added, "the write failed: \(String(describing: store.loadError))")
        let afterAdd = try #require(store.issues.first(where: { $0.id == target }))
        #expect(afterAdd.labels.contains("vbx-dot-test"))

        let removed = await store.setLabel("vbx-dot-test", on: [target], present: false)
        #expect(removed, "the removal failed: \(String(describing: store.loadError))")
        let afterRemove = try #require(store.issues.first(where: { $0.id == target }))
        #expect(!afterRemove.labels.contains("vbx-dot-test"))
    }

    @Test("One invocation covers the whole selection")
    func multipleBeadsInOneWrite() async throws {
        // `br label add` takes several issues, so a selection is one process
        // and one write — there is no half-applied state to report.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let editable = store.issues.filter { !$0.status.isImmutable }.prefix(3).map(\.id)
        try #require(editable.count >= 2)
        let ids = Set(editable)

        #expect(await store.setLabel("vbx-dot-bulk", on: ids, present: true))
        for id in ids {
            let bead = try #require(store.issues.first(where: { $0.id == id }))
            #expect(bead.labels.contains("vbx-dot-bulk"), "\(id) did not get the label")
        }
        #expect(store.labelPresence("vbx-dot-bulk", on: ids) == .all)
    }

    @Test("Presence has three answers, not two")
    func presenceIsThreeWay() async throws {
        // A checkmark that rounded "on some" to on or off would misreport what
        // the click is about to do.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let editable = store.issues.filter { !$0.status.isImmutable }.prefix(2).map(\.id)
        try #require(editable.count == 2)
        let one = editable[0], two = editable[1]

        #expect(store.labelPresence("vbx-dot-partial", on: [one, two]) == .none)
        #expect(await store.setLabel("vbx-dot-partial", on: [one], present: true))
        #expect(store.labelPresence("vbx-dot-partial", on: [one, two]) == .some)
        #expect(store.labelPresence("vbx-dot-partial", on: [one]) == .all)
    }

    @Test("A closed bead refuses, through the same gate as every other edit")
    func closedBeadsRefuse() async throws {
        // ADR-017's rule, reached through `editingUnavailableReason(for:)`
        // rather than a second gate of this feature's own.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let closed = try #require(store.issues.first(where: { $0.status.isImmutable })?.id)
        let before = try #require(store.issues.first(where: { $0.id == closed })).labels

        #expect(!(await store.setLabel("vbx-dot-refused", on: [closed], present: true)))
        let after = try #require(store.issues.first(where: { $0.id == closed })).labels
        #expect(after == before, "a closed bead's labels changed")
    }

    @Test("An empty label is not written")
    func emptyLabelsAreRefused() async throws {
        // Creating a label of spaces is not a thing to do quietly, and `br`
        // would take it.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let target = try #require(store.issues.first(where: { !$0.status.isImmutable })?.id)
        #expect(!(await store.setLabel("   ", on: [target], present: true)))
    }

    @Test("The Labels column declares the editor, and filtering keeps its homes")
    func theColumnEditsAndFilteringSurvives() throws {
        let spec = try #require(
            IssueListView.specs.first { $0.id == SortColumn.labels.rawValue })
        #expect(spec.editing == .labels)
        // Still sortable, and its identifier is still its SortColumn's raw
        // value — the contract asserted in `Table columns`.
        #expect(spec.sort == .labels)

        // Double-clicking a pill used to toggle a label *filter*, and the
        // cell's double-click now edits. Filtering has to keep a home, or this
        // removed a feature rather than moving a gesture: the sidebar's Labels
        // section and the Labels surface both offer it, and both show more than
        // the gesture did.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/VBXUI/SidebarView.swift"),
            encoding: .utf8)
        #expect(sidebar.contains("SidebarLabelsSection"))
        #expect(sidebar.contains("toggleLabelFilter"), "the sidebar no longer filters by label")
        #expect(ViewSurface.allCases.contains(.labels))
    }
}
