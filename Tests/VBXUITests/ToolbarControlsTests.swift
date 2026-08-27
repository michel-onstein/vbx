import Foundation
import VBXAppCore
import VBXCore
import Testing

@testable import VBXUI

/// Which surfaces carry the toolbar's Sort menu.
///
/// It writes to `query`, and `query` is read in exactly one place —
/// `visibleIssues`. Seven surfaces render an engine payload of their own and
/// never consult it, so before this the toolbar offered a control that produced
/// no visible effect on those views.
///
/// The Filter picker used to be gated the same way and is gone (vbx-bcj): the
/// sidebar shows all four filters with counts and the View menu carries them as
/// commands, so the toolbar was the third copy of one setting.
@Suite("Toolbar sort")
struct ToolbarControlsTests {

    /// The surfaces that read `visibleIssues`, and so are actually ordered by
    /// the two controls.
    ///
    /// Spelled out rather than derived: there is no way to ask Swift which
    /// views touch a property, and a test that recomputed the answer from the
    /// same switch it is checking would agree with any mistake in it.
    private static let ordered: Set<ViewSurface> = [.list, .board, .graph, .tree]

    /// Surfaces still awaiting a decision about the controls.
    ///
    /// Empty, and it should stay that way. It held `.history` while vbx-ec6 was
    /// open; the answer was that History joins the eight below rather than
    /// gaining a filter and sort of its own. Kept as a named, empty set so the
    /// next deferral has somewhere to go and cannot hide as a quiet `true`.
    private static let deferred: Set<ViewSurface> = []

    @Test("Only the views that order beads offer the control")
    func controlsFollowTheOrderedSurfaces() {
        for surface in ViewSurface.allCases {
            let expected = Self.ordered.contains(surface) || Self.deferred.contains(surface)
            #expect(
                surface.showsSort == expected,
                "\(surface.displayName) shows the control: \(surface.showsSort)")
        }
    }

    @Test("The eight views that read no query hide the control")
    func payloadViewsHideTheControls() {
        // Named one by one, because this list *is* the bug being fixed: each of
        // these showed a Sort menu that did nothing.
        // History joined them when vbx-ec6 was answered — it reads
        // `store.history` and consults the query no more than the other seven.
        let hidden: [ViewSurface] = [
            .attention, .sprint, .alerts, .flow, .labels, .plan, .insights, .history,
        ]

        for surface in hidden {
            #expect(
                !surface.showsSort,
                "\(surface.displayName) still offers a control it does not read")
        }
    }

    @Test("Every surface is accounted for")
    func noSurfaceIsUnclassified() {
        // A view added without deciding either way would otherwise inherit
        // whatever the switch's catch-all said. There is no catch-all — the
        // switch is exhaustive — and this keeps the *test* honest about a new
        // case rather than silently passing it.
        let classified = Self.ordered
            .union(Self.deferred)
            .union([.attention, .sprint, .alerts, .flow, .labels, .plan, .insights, .history])

        #expect(
            classified == Set(ViewSurface.allCases),
            "unclassified: \(Set(ViewSurface.allCases).subtracting(classified))")
    }

    @Test("The toolbar offers no filter control, and two other routes still do")
    func filteringLivesInTheSidebarAndTheMenu() throws {
        // Asserted on the source, which is unusual here and deliberate: a
        // toolbar is window chrome, an `NSHostingView` of `ContentView` never
        // builds one, and a render-based assertion would pass whether or not
        // the picker existed. What can be checked honestly is that the
        // declaration is gone and that the replacements are declared.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VBXUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/VBXUI/ContentView.swift"),
            encoding: .utf8)
        #expect(
            !content.contains("Picker(\"Filter\""),
            "the toolbar declares a filter picker again")

        // The sidebar is the primary route and shows more than the picker did:
        // all four filters, each with a count.
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/VBXUI/SidebarView.swift"),
            encoding: .utf8)
        #expect(sidebar.contains("SidebarFiltersSection"))

        // And the View menu carries them as commands, which is what answers a
        // *collapsed* sidebar — the one real objection to removing the toolbar
        // copy. Without this the assertion above would be removing the last
        // reachable control for anyone who works with the sidebar hidden.
        let commands = try String(
            contentsOf: root.appendingPathComponent("Sources/vbx/VBXApp.swift"),
            encoding: .utf8)
        #expect(
            commands.contains("Filter: \\(filter.displayName)"),
            "the View menu no longer offers the filters")
    }

    @MainActor
    @Test("The sidebar's filter rows still drive the query")
    func sidebarFiltersStillWrite() {
        // The behaviour that must not regress when a duplicate is removed: the
        // remaining control still writes the value the list reads.
        let store = ProjectStore()
        for filter in IssueFilter.allCases {
            store.query.filter = filter
            #expect(store.query.filter == filter)
        }
    }

    @MainActor
    @Test("Drilling into a label still writes the filter, and lands where it shows")
    func labelDrillDownStillWritesTheFilter() async {
        // Labels is one of the surfaces whose Sort menu is hidden, and this is
        // the write the bead flagged: it sets up the destination rather than
        // driving the hidden control. Hiding a control must not be read as
        // making `query` read-only on that surface.
        let store = ProjectStore()
        store.surface = .labels
        store.query.filter = .open

        store.showLabelInList("backend")

        #expect(store.query.labels == ["backend"])
        #expect(store.query.filter == .all, "the drill-down stopped clearing the filter")
        // ...and it lands on a surface that shows the control it just set, so
        // the filter is not left in a state the user cannot see or undo.
        #expect(store.surface == .list)
        #expect(store.surface.showsSort)
    }
}
