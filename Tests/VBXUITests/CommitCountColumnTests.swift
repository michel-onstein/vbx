import AppKit
import Foundation
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// The Commits column: how many commits the engine attributed to a bead.
///
/// Its whole difficulty is that **absent is not zero**. A column rendering
/// nought for a walk that has not run tells someone their work is uncorrelated
/// when nothing has been read — and that is the failure nobody reports, because
/// it looks like an answer.
@MainActor
@Suite("Commit count column")
struct CommitCountColumnTests {

    private func waitForHistory(_ store: ProjectStore, seconds: Double = 120) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if store.historyLoaded || store.historyError != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test("The count is the engine's attribution, not a recount")
    func countComesFromTheReport() async throws {
        let (store, directory) = try await Fixture.committedStore(eagerHistory: true)
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        await waitForHistory(store)
        try #require(store.historyLoaded)

        // Read straight off the report rather than recomputed: which commits
        // belong to a bead is the engine's judgement (ADR-001).
        for (id, history) in store.history.histories {
            #expect(store.commitCount(for: id) == history.commits.count)
        }
    }

    @Test("Not loaded is nil, not zero")
    func absentIsNotZero() async throws {
        // The assertion this column exists for.
        let (store, directory) = try await Fixture.writableStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        let id = try #require(store.issues.first?.id)

        #expect(!store.historyLoaded)
        #expect(store.commitCount(for: id) == nil, "an unread report reported a count")
        #expect(store.commitCounts == nil)
    }

    @Test("A bead the walk found nothing for is zero, not nil")
    func loadedButUncorrelatedIsZero() async throws {
        // The other half: once the walk has run, "no commits" is a real answer
        // and must not read as "not known".
        let (store, directory) = try await Fixture.committedStore(eagerHistory: true)
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: directory)
        }
        await waitForHistory(store)
        try #require(store.historyLoaded)

        let uncorrelated = store.issues.first { store.history.histories[$0.id] == nil }
        if let uncorrelated {
            #expect(store.commitCount(for: uncorrelated.id) == 0)
        }
        // Whatever the fixture holds, every bead has *some* answer now.
        for issue in store.issues {
            #expect(store.commitCount(for: issue.id) != nil)
        }
    }

    @Test("The cell draws zero and unknown differently")
    func zeroAndUnknownLookDifferent() throws {
        // Rendered, because this is the one thing a reader must be able to tell
        // apart at a glance, and both are "a short string in a narrow column".
        func render(_ cell: CommitCountCell) throws -> RenderResult {
            let size = CGSize(width: 78, height: 24)
            // An opaque background, so ink is measured against a known ground
            // rather than against transparency.
            let host = NSHostingView(
                rootView: AnyView(
                    cell.frame(width: size.width, height: size.height)
                        .background(Color.white)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            return try ViewCapture.image(of: host)
        }

        let zero = try render(CommitCountCell(count: 0, reason: "x")).inkCoverage()
        let unknown = try render(CommitCountCell(count: nil, reason: "x")).inkCoverage()
        let three = try render(CommitCountCell(count: 3, reason: "x")).inkCoverage()

        // Something drew in each, or the comparisons below would pass on three
        // identically blank images.
        #expect(zero > 0, "the zero cell drew nothing")
        #expect(unknown > 0, "the unknown cell drew nothing")
        #expect(three > 0, "the counted cell drew nothing")

        // "0" and "—" are different glyphs, so they put different amounts of
        // ink on screen; that is the whole claim — a reader can tell them apart
        // at a glance.
        #expect(zero != unknown, "zero and unknown render alike")
    }

    @Test("The column is declared once, sortable, and not editable")
    func theColumnFollowsTheContract() throws {
        let spec = try #require(
            IssueListView.specs.first { $0.id == SortColumn.commits.rawValue })
        // A sortable column's identifier must equal its SortColumn raw value —
        // the contract `Table columns` asserts for every one of them.
        #expect(spec.sort == .commits)
        #expect(spec.id == SortColumn.commits.rawValue)
        #expect(spec.editing == nil, "a count derived from git is not editable")
        #expect(spec.title == "Commits")
    }

    @Test("Ordering by commits is refused until the counts exist")
    func sortingIsRefusedWhileUnknown() {
        // The trap PageRank already solved: sorting by absent values orders the
        // list by zeros and leaves nothing on screen to explain the order.
        #expect(SortColumn.commits.requiresHistory)
        #expect(SortMode.commitsDescending.requiresHistory)
        #expect(SortMode.commitsAscending.requiresHistory)
        // And it is only this column.
        for column in SortColumn.allCases where column != .commits {
            #expect(!column.requiresHistory, "\(column.rawValue) claims to need history")
        }
    }

    @Test("The ordering sorts by the counts it is given")
    func orderingUsesTheCounts() {
        var one = Bead(id: "vbx-1", title: "one")
        var two = Bead(id: "vbx-2", title: "two")
        var three = Bead(id: "vbx-3", title: "three")
        one.status = .open
        two.status = .open
        three.status = .open

        let query = IssueQuery(filter: .all, sort: .commitsDescending)
        let sorted = query.apply(
            to: [one, two, three], commits: ["vbx-1": 2, "vbx-2": 9, "vbx-3": 0])
        #expect(sorted.map(\.id) == ["vbx-2", "vbx-1", "vbx-3"])

        let ascending = IssueQuery(filter: .all, sort: .commitsAscending).apply(
            to: [one, two, three], commits: ["vbx-1": 2, "vbx-2": 9, "vbx-3": 0])
        #expect(ascending.map(\.id) == ["vbx-3", "vbx-1", "vbx-2"])
    }
}
