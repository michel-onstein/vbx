import AppKit
import SwiftUI
import Testing
import VBXCore

@testable import VBXUI

/// The trackpad reaches the graph through two things that can be asserted —
/// ``GraphCamera``'s arithmetic and ``GraphScrollCatcher``'s reading of a scroll
/// event — and one that cannot: whether macOS delivers the gesture at all. That
/// is the same split ADR-014 records for a click inside a table, and the reason
/// the camera is a value type rather than a pair of `@State` numbers.
@MainActor
@Suite("Graph gestures")
struct GraphGestureTests {

    /// Points either side of a zoom land within a fraction of a point.
    private func expectClose(
        _ a: CGPoint, _ b: CGPoint, _ what: String, tolerance: CGFloat = 0.001
    ) {
        #expect(
            abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance,
            "\(what): \(a) vs \(b)")
    }

    // MARK: - Zoom

    @Test("A pinch keeps the layout point under the fingers under the fingers")
    func pinchIsAnchored() {
        // Several starting cameras, because an anchored zoom that only works
        // from the identity camera works exactly once.
        let starts = [
            GraphCamera(),
            GraphCamera(zoom: 0.5, pan: CGSize(width: 40, height: -25)),
            GraphCamera(zoom: 1.8, pan: CGSize(width: -120, height: 60)),
        ]
        let anchors = [CGPoint(x: 0, y: 0), CGPoint(x: 320, y: 180), CGPoint(x: 999, y: 12)]

        for start in starts {
            for anchor in anchors {
                for factor in [1.05, 0.5, 1.9] as [CGFloat] {
                    let before = start.canvasPoint(for: anchor)
                    let after = start.magnified(by: factor, around: anchor)
                    expectClose(
                        after.canvasPoint(for: anchor), before,
                        "anchor moved zooming \(factor)× about \(anchor)")
                    // Clamped, because 1.8× a 1.9 zoom is past the far rail —
                    // and the anchor has to hold there too, which is the case
                    // the assertion above is really buying.
                    let asked = start.zoom * factor
                    #expect(
                        after.zoom
                            == min(
                                max(asked, GraphCamera.zoomRange.lowerBound),
                                GraphCamera.zoomRange.upperBound))
                }
            }
        }
    }

    @Test("The buttons zoom about the middle of the pane")
    func buttonZoomIsAnchored() {
        // What the plus button does: a step, anchored at the centre. The point
        // in the middle of the pane is the one that must not move, because it
        // is the one the user is looking at.
        let pane = CGSize(width: 800, height: 600)
        let centre = CGPoint(x: pane.width / 2, y: pane.height / 2)
        var camera = GraphCamera(zoom: 1, pan: CGSize(width: 30, height: 20))
        let subject = camera.canvasPoint(for: centre)

        for _ in 0..<4 {
            camera = camera.zoomed(to: camera.zoom + 0.15, around: centre)
            expectClose(camera.canvasPoint(for: centre), subject, "centre drifted while zooming in")
        }
        #expect(abs(camera.zoom - 1.6) < 0.0001)
    }

    @Test("Zoom stops at the ends of its range, and stopping is a no-op")
    func zoomClamps() {
        let anchor = CGPoint(x: 210, y: 90)

        let zoomedIn = GraphCamera().magnified(by: 50, around: anchor)
        #expect(zoomedIn.zoom == GraphCamera.zoomRange.upperBound)
        // At the rail a further pinch must change *nothing*. Clamping the zoom
        // while still recentring the pan would slide the graph a little on
        // every event of a gesture that has visibly stopped scaling.
        #expect(zoomedIn.magnified(by: 2, around: anchor) == zoomedIn)
        #expect(zoomedIn.magnified(by: 2, around: CGPoint(x: 0, y: 0)) == zoomedIn)

        let zoomedOut = GraphCamera().magnified(by: 0.001, around: anchor)
        #expect(zoomedOut.zoom == GraphCamera.zoomRange.lowerBound)
        #expect(zoomedOut.magnified(by: 0.5, around: anchor) == zoomedOut)

        // A nonsense factor is refused rather than producing an inverted or
        // infinite camera: a magnification of zero would divide by it later.
        #expect(GraphCamera().magnified(by: 0, around: anchor) == GraphCamera())
        #expect(GraphCamera().magnified(by: -1, around: anchor) == GraphCamera())
    }

    // MARK: - Pan

    @Test("Panning accumulates, whichever gesture it came from")
    func panAccumulates() {
        // Two-finger scroll and a drag are the same operation on the camera,
        // which is what lets one continue where the other left off.
        let camera = GraphCamera(zoom: 1.5)
            .panned(by: CGSize(width: 10, height: 5))
            .panned(by: CGSize(width: -3, height: 20))
        #expect(camera.pan == CGSize(width: 7, height: 25))
        // A pan never changes the scale — the readout beside the buttons says
        // so, and a scroll that quietly rescaled would make it a lie.
        #expect(camera.zoom == 1.5)
    }

    @Test("Centring puts a narrow graph in the middle and leaves a top margin")
    func centring() {
        let camera = GraphCamera().centred(
            content: CGSize(width: 400, height: 2000), in: CGSize(width: 1000, height: 600))
        #expect(camera.pan == CGSize(width: 300, height: 20))

        // Wider than the pane: pinned to the left edge rather than pushed off
        // it, because a negative offset hides the roots.
        let wide = GraphCamera().centred(
            content: CGSize(width: 4000, height: 500), in: CGSize(width: 1000, height: 600))
        #expect(wide.pan.width == 0)

        // Nothing laid out yet: leave the camera alone rather than centring on
        // a zero-sized graph.
        let empty = GraphCamera(zoom: 2, pan: CGSize(width: 5, height: 6))
            .centred(content: .zero, in: CGSize(width: 1000, height: 600))
        #expect(empty == GraphCamera(zoom: 2, pan: CGSize(width: 5, height: 6)))
    }

    // MARK: - Hit-testing

    @Test("A click lands on the node drawn under it, at any zoom")
    func hitTestingFollowsTheCamera() throws {
        let layout = GraphLayoutEngine.layout(
            nodes: ["a", "b", "c"],
            edges: [
                GraphEdge(from: "a", to: "b", type: .blocks),
                GraphEdge(from: "b", to: "c", type: .blocks),
            ])
        let node = try #require(layout.nodes.first)

        // Every camera the gestures can produce: scaled, offset, both.
        for camera in [
            GraphCamera(),
            GraphCamera(zoom: 2.4, pan: CGSize(width: -80, height: 140)),
            GraphCamera(zoom: 0.35, pan: CGSize(width: 260, height: -40)),
        ] {
            let canvas = GraphCanvas(
                layout: layout, issuesByID: [:], actionable: [], pageRank: nil, camera: camera)
            // Where the drawing puts the node: the same transform the Canvas
            // applies, written out here so the test would fail if `node(at:)`
            // grew its own copy of the arithmetic again.
            let onScreen = CGPoint(
                x: node.position.x * camera.zoom + camera.pan.width,
                y: node.position.y * camera.zoom + camera.pan.height)

            #expect(canvas.node(at: onScreen)?.id == node.id, "missed the node at \(camera)")
            // Far away from every node, nothing is selected — a click on empty
            // space must not grab the nearest node from across the pane.
            #expect(canvas.node(at: CGPoint(x: onScreen.x + 4000, y: onScreen.y + 4000)) == nil)
        }
    }

    // MARK: - Reading a scroll event

    /// A scroll event as the trackpad driver or a wheel would report it.
    ///
    /// `wheel1` is the vertical axis and `wheel2` the horizontal, and the unit
    /// is what separates the two devices: a trackpad reports pixels, a wheel
    /// reports lines.
    private func scroll(dx: Int32, dy: Int32, units: CGScrollEventUnit) throws -> NSEvent {
        let cg = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("A trackpad scrolls in points; a wheel notch is worth a line")
    func scrollTranslation() throws {
        // Precise deltas are already the distance to pan, so they pass through
        // untouched — that is what makes the graph track the fingers.
        let trackpad = try scroll(dx: -7, dy: 12, units: .pixel)
        #expect(trackpad.hasPreciseScrollingDeltas)
        #expect(GraphScrollCatcher.translation(of: trackpad) == CGSize(width: -7, height: 12))

        // A wheel reports a count of lines. Unscaled it would move the graph by
        // a point per notch, which reads as a dead wheel.
        let wheel = try scroll(dx: 0, dy: 1, units: .line)
        #expect(!wheel.hasPreciseScrollingDeltas)
        #expect(GraphScrollCatcher.translation(of: wheel) == CGSize(width: 0, height: 16))
    }

    @Test("The catcher covers the graph, and knows what is outside it")
    func catcherGeometry() throws {
        // Hosted for real, because this is the half of the monitor a test can
        // reach: whether the overlay got a frame, and whether a window-space
        // point converts into it correctly. A zero-sized overlay would match no
        // scroll at all and look exactly like a gesture macOS never delivered.
        let size = CGSize(width: 400, height: 300)
        let host = Self.hosted(
            Color.clear.overlay { GraphScrollCatcher { _ in } }, size: size)

        let catcher = try #require(
            Self.catcher(in: host), "the catcher was never added to the hierarchy")
        #expect(catcher.bounds.width == size.width)
        #expect(catcher.bounds.height == size.height)

        // Window coordinates: the hosting view fills the window, so the middle
        // of one is the middle of the other.
        #expect(GraphScrollCatcher.isOverGraph(CGPoint(x: 200, y: 150), in: catcher))
        #expect(GraphScrollCatcher.isOverGraph(CGPoint(x: 1, y: 1), in: catcher))
        // Outside: a scroll over another pane must pass through untouched, or
        // the graph steals scrolling from the rest of the window.
        #expect(!GraphScrollCatcher.isOverGraph(CGPoint(x: 460, y: 150), in: catcher))
        #expect(!GraphScrollCatcher.isOverGraph(CGPoint(x: 200, y: -20), in: catcher))
    }

    /// Hosts a view in a window, laid out — `Snapshot.render` draws and
    /// discards, and what is wanted here is the live hierarchy.
    private static func hosted<V: View>(_ view: V, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(
            rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(host.frame, display: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The catcher's own view, wherever SwiftUI put it.
    private static func catcher(in view: NSView) -> NSView? {
        if view is GraphScrollCatcher.ScrollCatchingView { return view }
        for subview in view.subviews {
            if let found = catcher(in: subview) { return found }
        }
        return nil
    }

    @Test("The scroll catcher never takes a click")
    func catcherIsInvisibleToTheMouse() {
        // The mouse belongs to SwiftUI: selection is a tap, panning is a drag,
        // and hover draws the highlight. A view that hit-tests would take all
        // three and have to hand them back along the responder chain.
        let view = GraphScrollCatcher.ScrollCatchingView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.hitTest(NSPoint(x: 200, y: 150)) == nil)
    }

    // MARK: - Pixels

    @Test("The camera moves what is actually drawn")
    func cameraReachesTheDrawing() throws {
        // The arithmetic above is worth nothing if the Canvas ignores it. Two
        // renders of one graph: in view, and panned out of the pane.
        let layout = GraphLayoutEngine.layout(
            nodes: ["a", "b", "c", "d"],
            edges: [
                GraphEdge(from: "a", to: "b", type: .blocks),
                GraphEdge(from: "b", to: "c", type: .blocks),
                GraphEdge(from: "a", to: "d", type: .blocks),
            ])
        let issues = ["a", "b", "c", "d"].reduce(into: [String: VBXCore.Issue]()) {
            $0[$1] = VBXCore.Issue(id: $1, title: $1.uppercased(), status: .open)
        }
        let size = CGSize(width: 420, height: 320)

        func render(_ camera: GraphCamera, _ name: String) throws -> RenderResult {
            try Snapshot.render(
                GraphCanvas(
                    layout: layout, issuesByID: issues, actionable: [], pageRank: nil,
                    camera: camera),
                name: name,
                size: size)
        }

        let framed = try render(
            GraphCamera().centred(content: layout.size, in: size), "graph-camera-framed")
        #expect(framed.inkCoverage() > 0.01, "graph drew nothing to begin with")

        let scrolledAway = try render(
            GraphCamera().panned(by: CGSize(width: 5_000, height: 5_000)), "graph-camera-panned")
        let inks = "framed \(framed.inkCoverage()), panned \(scrolledAway.inkCoverage())"
        #expect(
            scrolledAway.inkCoverage() < framed.inkCoverage() / 4,
            "panning did not move the drawing (\(inks))")

        // Zoomed in on one corner, the same graph covers more of the pane. A
        // scale the drawing ignored would score the same as the framed view.
        let zoomed = try render(
            GraphCamera().magnified(by: 3, around: .zero), "graph-camera-zoomed")
        #expect(
            zoomed.inkCoverage() != framed.inkCoverage(),
            "zooming changed nothing on screen")
    }
}
