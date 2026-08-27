import AppKit
import SwiftUI

/// Turns two-finger scrolling over the graph into a pan.
///
/// ## Why this is AppKit
///
/// SwiftUI has a gesture for a pinch (``MagnifyGesture``) and none for a
/// scroll. `ScrollView` is not the missing piece: the graph's camera is a
/// transform inside a `Canvas`, not a scrolled subview, and wrapping it would
/// hand the offset to a container that knows nothing about the zoom.
///
/// ## Why a monitor rather than a view that takes the event
///
/// A scroll event is delivered to the view the pointer is over. An `NSView`
/// that returns itself from `hitTest(_:)` would receive it — and would also
/// receive every click, taking the tap-to-select and drag-to-pan gestures away
/// from SwiftUI and putting them on the responder chain to be forwarded by
/// hand. ADR-014 is the record of what that costs. A local monitor sees the
/// event before delivery without being in the hit-testing path at all, so this
/// view stays as invisible to the mouse as ``BeadLinkCursors``: it exists to be
/// a rectangle in a window, and the rectangle is what scopes the monitor.
struct GraphScrollCatcher: NSViewRepresentable {
    /// Called with the pan, in screen points, for each scroll event over the
    /// view.
    var onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollCatchingView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The closure captures this render's state, so it has to be replaced
        // rather than installed once: a stale one pans a camera that no longer
        // exists.
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    /// A rectangle that never takes a click.
    ///
    /// The whole point is to leave the mouse to SwiftUI — selection, hover and
    /// the drag-pan are all still its gestures — while giving the monitor a
    /// frame to test a scroll's location against.
    final class ScrollCatchingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var onScroll: (CGSize) -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(onScroll: @escaping (CGSize) -> Void) {
            self.onScroll = onScroll
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Consumes a scroll over the graph; passes everything else through.
        ///
        /// The local event monitor fires on the main thread, so hopping into
        /// `MainActor` isolation is sound — the same reasoning as
        /// ``TerminalKeyCatcher``.
        @MainActor
        func handle(_ event: NSEvent) -> NSEvent? {
            // Scoped by window as well as by rectangle: with two workspaces
            // open, both graphs have a catcher at the same place on screen, and
            // the one being scrolled is the one whose window got the event.
            guard let view, let window = view.window, event.window === window,
                GraphScrollCatcher.isOverGraph(event.locationInWindow, in: view)
            else { return event }

            onScroll(GraphScrollCatcher.translation(of: event))
            // Consumed, so nothing enclosing the graph scrolls as well.
            return nil
        }
    }

    /// Whether a scroll at `locationInWindow` happened over the graph.
    ///
    /// Split out because it is the half of the monitor that can be asserted: a
    /// synthesised scroll event carries no window, so a test cannot post one
    /// and watch it arrive, but it *can* host the catcher for real and ask
    /// whether a point lands on it. That covers what actually goes wrong here —
    /// an overlay that ended up with a zero frame, or a coordinate conversion
    /// that forgot AppKit's origin is the bottom-left.
    static func isOverGraph(_ locationInWindow: CGPoint, in view: NSView) -> Bool {
        view.bounds.contains(view.convert(locationInWindow, from: nil))
    }

    /// The pan one scroll event asks for, in screen points.
    ///
    /// A trackpad reports precise deltas already measured in points, and adding
    /// them to the pan is what makes the graph follow the fingers. A mouse
    /// wheel reports *lines*, and a line is not a distance: unscaled, a notch
    /// moves the graph by a point and the wheel looks broken. 16 points is a
    /// line of body text, which is the unit the number is counting.
    static func translation(of event: NSEvent) -> CGSize {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        return CGSize(
            width: event.scrollingDeltaX * scale,
            height: event.scrollingDeltaY * scale)
    }
}
