import CoreGraphics

/// Where the graph is being looked at from: one scale, one offset.
///
/// A value type rather than two pieces of view state because every input — the
/// zoom buttons, a pinch, a two-finger scroll, a drag — is one of the same two
/// operations, and the part worth getting right is shared: keeping the point
/// under the fingers still while the scale changes. As a value it is also the
/// only part of a trackpad gesture that can be asserted, since a pinch does not
/// arrive in a headless test.
///
/// Screen and layout coordinates are both in points and are easy to confuse.
/// ``canvasPoint(for:)`` is the only conversion, and drawing, hit-testing and
/// the anchored zoom all go through it rather than repeating the arithmetic.
struct GraphCamera: Equatable {
    /// Screen points per layout point.
    var zoom: CGFloat = 1

    /// Where the layout's origin sits on screen.
    var pan: CGSize = .zero

    /// The scales the graph is legible at.
    ///
    /// Below a quarter the labels are unreadable; above 3× a single node fills
    /// the pane. One range shared by every input, so a pinch cannot reach a
    /// scale the buttons refuse — which is what makes the percentage readout
    /// trustworthy.
    static let zoomRange: ClosedRange<CGFloat> = 0.25...3

    /// The layout point drawn at `viewPoint`.
    func canvasPoint(for viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - pan.width) / zoom, y: (viewPoint.y - pan.height) / zoom)
    }

    /// Multiplies the scale, holding `anchor` over the same layout point.
    ///
    /// This is what makes a pinch feel attached to the graph rather than to the
    /// pane: the node between the fingers stays between the fingers. Scaling
    /// without it moves whatever is under the cursor away, and the user chases
    /// it with a drag afterwards.
    func magnified(by factor: CGFloat, around anchor: CGPoint) -> GraphCamera {
        guard factor > 0 else { return self }
        return zoomed(to: zoom * factor, around: anchor)
    }

    /// Sets the scale, holding `anchor` over the same layout point.
    ///
    /// Clamping happens here and nowhere else. A pinch beyond a rail is a
    /// no-op rather than a pan: recentring on a scale that did not change is a
    /// drift the user did not ask for, and at the rail every further event
    /// would add more of it.
    func zoomed(to newZoom: CGFloat, around anchor: CGPoint) -> GraphCamera {
        let clamped = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard clamped != zoom else { return self }
        let fixed = canvasPoint(for: anchor)
        return GraphCamera(
            zoom: clamped,
            pan: CGSize(
                width: anchor.x - fixed.x * clamped,
                height: anchor.y - fixed.y * clamped))
    }

    /// Moves the view by a screen-space translation.
    func panned(by translation: CGSize) -> GraphCamera {
        GraphCamera(
            zoom: zoom,
            pan: CGSize(width: pan.width + translation.width, height: pan.height + translation.height)
        )
    }

    /// The camera that centres a layout of `content` size in a pane of `pane`
    /// size at the current scale.
    ///
    /// Vertically it is a margin rather than a centring: layered graphs are
    /// read from the roots down, so the top edge is the interesting one and
    /// centring a tall graph would hide it.
    func centred(content: CGSize, in pane: CGSize) -> GraphCamera {
        guard content.width > 0 else { return self }
        return GraphCamera(
            zoom: zoom,
            pan: CGSize(width: max(0, (pane.width - content.width * zoom) / 2), height: 20))
    }
}
