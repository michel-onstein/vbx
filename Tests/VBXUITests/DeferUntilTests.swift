import AppKit
import Foundation
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// A bead's `defer_until`, in the Inspector and the list.
///
/// The trap is the same one every readiness surface has: whether a deferral
/// still withholds a bead is decided at the engine's clock, and the app must
/// show that verdict rather than compare the date to the Mac's clock itself.
/// So everything drawn as "deferred" here is keyed off `store.deferred`, and the
/// readiness fixture supplies one deferral in 2099 and one that has passed.
@MainActor
@Suite("Deferred until")
struct DeferUntilTests {

    private func readinessStore() async -> ProjectStore {
        let store = ProjectStore()
        store.skipPhase2 = true
        await store.open(path: Fixture.readinessPath)
        return store
    }

    /// Hosts `view` in light appearance, so the warning colour is measured
    /// against a known ground. In dark mode the yellow "actionable" line,
    /// antialiased onto a dark background, passes for orange.
    private func host(_ view: some View, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(
            rootView: AnyView(
                view.frame(width: size.width, height: size.height)
                    .background(Color.white)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    // MARK: Inspector

    @Test("The Inspector names a future deferral, and says nothing for a passed one")
    func inspectorShowsOnlyAFutureDeferral() async throws {
        let store = await readinessStore()
        defer { Task { await store.close() } }
        let size = CGSize(width: 340, height: 600)

        func render(_ id: String) throws -> RenderResult {
            #expect(store.select(id: id), "\(id) is not in the fixture")
            let (view, window) = host(InspectorView().environmentObject(store), size: size)
            defer { window.contentView = nil }
            let result = try ViewCapture.image(of: view)
            // Kept for a human to look at, like every other snapshot.
            let png = NSBitmapImageRep(cgImage: result.image).representation(
                using: .png, properties: [:])
            try png?.write(
                to: Snapshot.outputDirectory.appendingPathComponent("inspector-deferral-\(id).png"))
            return result
        }

        let future = try render("rdy-5")
        let passed = try render("rdy-6")
        let statusOnly = try render("rdy-4")

        // Both drew an Inspector, so a zero below is about the notice, not a
        // blank render.
        #expect(future.inkCoverage() > 0.01)
        #expect(passed.inkCoverage() > 0.01)

        // The notice is the only orange in the Inspector. Scoped to the header
        // — the top of the pane — so the description below cannot carry it.
        let header = CGRect(x: 0, y: 0, width: size.width, height: 200)
        #expect(future.warningInk(in: header) > 0.0005, "the 2099 deferral is not shown")
        #expect(passed.warningInk(in: nil) == 0, "a passed deferral is still shown")
        // Deferred by status, with no date: the status chip says it; there is
        // no date to name.
        #expect(statusOnly.warningInk(in: nil) == 0, "a status-only deferral showed a date")
    }

    @Test("The notice names the date the deferral lifts")
    func reasonNamesTheDate() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2099-01-01T12:00:00Z"))
        let reason = DeferUntilCell.reason(date)
        #expect(reason.hasPrefix("Deferred until "))
        #expect(reason.contains("2099"), "the reason does not name the year: \(reason)")
        #expect(reason.contains("Ready"), "the reason does not say what it withholds")
    }

    // MARK: List column

    @Test("The column is declared once, sortable, and shown by default")
    func theColumnFollowsTheContract() throws {
        let spec = try #require(
            IssueListView.specs.first { $0.id == SortColumn.deferUntil.rawValue })
        // A sortable column's identifier must equal its SortColumn raw value.
        #expect(spec.sort == .deferUntil)
        #expect(spec.editing == nil, "the list does not edit a deferral")
        #expect(spec.title == "Deferred until")
        // Shown by default: a deferral that must be switched on to be seen is
        // the gap this closes.
        #expect(!BeadTableLayout().isHidden(spec.id))
        // And not protected, so someone who never defers can hide it.
        #expect(!spec.isProtected)
    }

    @Test("A future deferral, a passed one and none draw three different cells")
    func cellsAreDistinct() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        let size = CGSize(width: 110, height: 24)

        func render(_ cell: DeferUntilCell) throws -> RenderResult {
            let (view, window) = host(cell, size: size)
            defer { window.contentView = nil }
            return try ViewCapture.image(of: view)
        }

        let deferred = try render(DeferUntilCell(date: date, isDeferred: true))
        let passed = try render(DeferUntilCell(date: date, isDeferred: false))
        let none = try render(DeferUntilCell(date: nil, isDeferred: false))

        #expect(deferred.inkCoverage() > 0, "a deferred cell drew nothing")
        #expect(passed.inkCoverage() > 0, "a passed deferral drew nothing")
        #expect(none.inkCoverage() > 0, "the absent dash drew nothing")

        // The engine's verdict is what turns it orange — the same date with the
        // verdict withdrawn is not.
        #expect(deferred.warningInk(in: nil) > 0, "a deferred bead is not marked")
        #expect(passed.warningInk(in: nil) == 0, "a passed deferral is still marked")
        // A dash is less ink than a date.
        #expect(none.inkCoverage() < passed.inkCoverage())
    }

    @Test("The real table marks the deferred bead's cell, and not the passed one's")
    func columnInTheRealTable() async throws {
        let store = await readinessStore()
        defer { Task { await store.close() } }
        store.query.filter = .all

        let size = CGSize(width: 1700, height: 700)
        let (host, window) = host(IssueListView().environmentObject(store), size: size)
        defer { window.contentView = nil }

        func tables(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let table = view as? NSTableView { found.append(table) }
            for sub in view.subviews { found += tables(in: sub) }
            return found
        }
        let table = try #require(tables(in: host).first, "the table did not render")
        let column = try #require(
            table.tableColumns.firstIndex {
                $0.identifier.rawValue == SortColumn.deferUntil.rawValue
            }, "the column is not in the table")
        try #require(!table.tableColumns[column].isHidden, "the column is hidden by default")

        func cellRect(_ id: String) throws -> CGRect {
            let row = try #require(store.visibleIssues.firstIndex { $0.id == id })
            return host.convert(table.frameOfCell(atColumn: column, row: row), from: table)
        }
        let image = try ViewCapture.image(of: host)
        let future = try cellRect("rdy-5")
        let passed = try cellRect("rdy-6")
        let none = try cellRect("rdy-1")

        #expect(image.inkCoverage(in: future) > 0, "rdy-5's deferral cell is blank")
        #expect(image.inkCoverage(in: passed) > 0, "rdy-6's deferral cell is blank")
        #expect(image.warningInk(in: future) > 0, "rdy-5 is deferred but not marked")
        #expect(image.warningInk(in: passed) == 0, "rdy-6's deferral passed but is marked")
        #expect(image.warningInk(in: none) == 0, "a bead with no deferral is marked")
    }

    @Test("The deferral is in the row fingerprint, so the table reloads when it lifts")
    func fingerprintFollowsTheDeferral() async throws {
        // The engine's clock passing a deferral changes no field of the bead:
        // like a commit clearing the uncommitted marks, a fingerprint of the
        // record alone would stay the same, and the row would keep its marker.
        let store = await readinessStore()
        defer { Task { await store.close() } }
        let bead = try #require(store.issuesByID["rdy-5"])

        func fingerprint(deferred: Bool) -> [String] {
            let rows = [IssueRow(issue: bead, metrics: store.metrics, isDeferred: deferred)]
            let table = BeadTable(
                rows: rows, specs: IssueListView.specs,
                selection: .constant([]), sort: .constant(.default),
                layout: .constant(BeadTableLayout()),
                canSort: { _ in true },
                content: { _, _ in AnyView(EmptyView()) },
                editableText: { _, row in row.issue.title },
                commitText: { _, _, _ in },
                valueMenu: { _, _ in nil },
                rowMenu: { _ in nil },
                editRefusal: { _ in nil },
                uncommittedReason: { _ in nil })
            return BeadTable.Coordinator(table).fingerprint(of: rows)
        }
        #expect(fingerprint(deferred: true) != fingerprint(deferred: false))
    }

    // MARK: Ready filter

    @Test("The Ready filter's explanation names the deferrals")
    func readyExplanationNamesDeferral() {
        #expect(!IssueFilter.ready.explanation(deferred: 0).contains("deferred"))
        #expect(IssueFilter.ready.explanation(deferred: 1).contains("1 bead is deferred"))
        #expect(IssueFilter.ready.explanation(deferred: 3).contains("3 beads are deferred"))
        // Only Ready: the other filters do not withhold anything by date.
        for filter in IssueFilter.allCases where filter != .ready {
            #expect(!filter.explanation(deferred: 3).contains("deferred"))
        }
    }
}

extension RenderResult {
    /// Fraction of `region` (points, top-left; whole image when nil) drawn in
    /// the deferral's orange.
    ///
    /// Orange is the one colour the deferral uses and nothing else in the
    /// Inspector or the list does, so its presence is the notice's. Yellow —
    /// the actionable bolt — has a green channel too high to pass, provided
    /// the render is in light appearance.
    func warningInk(in region: CGRect?) -> Double {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data)
        else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3 else { return 0 }

        // Channel order from the image itself rather than assumed.
        let alpha = image.alphaInfo
        let alphaFirst =
            alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let (ri, gi, bi): (Int, Int, Int)
        switch (little, alphaFirst) {
        case (false, false): (ri, gi, bi) = (0, 1, 2)  // RGBA
        case (false, true): (ri, gi, bi) = (1, 2, 3)  // ARGB
        case (true, true): (ri, gi, bi) = (2, 1, 0)  // BGRA
        case (true, false): (ri, gi, bi) = (3, 2, 1)  // ABGR
        }

        var minX = 0, minY = 0, maxX = width, maxY = height
        if let region {
            let scale = CGFloat(width) / CGFloat(pointWidth)
            minX = max(0, Int(region.minX * scale))
            minY = max(0, Int(region.minY * scale))
            maxX = min(width, Int(region.maxX * scale))
            maxY = min(height, Int(region.maxY * scale))
            guard minX < maxX, minY < maxY else { return 0 }
        }

        var hits = 0, sampled = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(ptr[offset + ri]), g = Int(ptr[offset + gi]), b = Int(ptr[offset + bi])
                if r >= 200, (90...185).contains(g), b <= 90 { hits += 1 }
                sampled += 1
            }
        }
        return sampled == 0 ? 0 : Double(hits) / Double(sampled)
    }
}
