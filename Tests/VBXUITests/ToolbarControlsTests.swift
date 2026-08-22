import VBXAppCore
import Testing

@testable import VBXUI

/// Which surfaces carry the toolbar's Filter picker and Sort menu.
///
/// Both controls write to `query`, and `query` is read in exactly one place —
/// `visibleIssues`. Seven surfaces render an engine payload of their own and
/// never consult it, so before this the toolbar offered two controls that
/// produced no visible effect on those views.
@Suite("Toolbar filter and sort")
struct ToolbarControlsTests {

    /// The surfaces that read `visibleIssues`, and so are actually ordered by
    /// the two controls.
    ///
    /// Spelled out rather than derived: there is no way to ask Swift which
    /// views touch a property, and a test that recomputed the answer from the
    /// same switch it is checking would agree with any mistake in it.
    private static let ordered: Set<ViewSurface> = [.list, .board, .graph, .tree]

    /// Ignores the query, but keeps the controls pending a decision of its own.
    ///
    /// Tracked as vbx-ec6. When that is answered this set should be empty —
    /// either History gains a filter and sort that mean something in its own
    /// terms, or it joins the seven below.
    private static let deferred: Set<ViewSurface> = [.history]

    @Test("Only the views that order beads offer the controls")
    func controlsFollowTheOrderedSurfaces() {
        for surface in ViewSurface.allCases {
            let expected = Self.ordered.contains(surface) || Self.deferred.contains(surface)
            #expect(
                surface.showsFilterAndSort == expected,
                "\(surface.displayName) shows the controls: \(surface.showsFilterAndSort)")
        }
    }

    @Test("The seven engine-payload views hide both controls")
    func payloadViewsHideTheControls() {
        // Named one by one, because this list *is* the bug being fixed: each of
        // these showed a Filter picker and a Sort menu that did nothing.
        let hidden: [ViewSurface] = [
            .attention, .sprint, .alerts, .flow, .labels, .plan, .insights,
        ]

        for surface in hidden {
            #expect(
                !surface.showsFilterAndSort,
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
            .union([.attention, .sprint, .alerts, .flow, .labels, .plan, .insights])

        #expect(
            classified == Set(ViewSurface.allCases),
            "unclassified: \(Set(ViewSurface.allCases).subtracting(classified))")
    }

    @MainActor
    @Test("Drilling into a label still writes the filter, and lands where it shows")
    func labelDrillDownStillWritesTheFilter() async {
        // Labels is one of the surfaces whose picker is now hidden, and this is
        // the write the bead flagged: it sets up the destination rather than
        // driving the hidden control. Hiding a picker must not be read as
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
        #expect(store.surface.showsFilterAndSort)
    }
}
