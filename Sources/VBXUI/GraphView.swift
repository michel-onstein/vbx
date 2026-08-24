import VBXAppCore
import VBXCore
import SwiftUI

/// Pure drawing surface for a laid-out dependency graph.
///
/// Split out of `GraphView` so it takes everything it needs as plain values.
/// That makes it synchronously renderable, which is what lets a snapshot test
/// capture the real drawing instead of the "laying out…" placeholder.
struct GraphCanvas: View {
    let layout: GraphLayout
    let issuesByID: [String: Issue]
    let actionable: Set<String>
    let pageRank: [String: Double]?
    var selection: String?
    var hovered: String?
    var camera = GraphCamera()

    /// Node radius encodes PageRank when available, uniform otherwise — an
    /// un-computed metric must not masquerade as "all equally important".
    func radius(for id: String) -> CGFloat {
        guard let pageRank, let value = pageRank[id], let maxPR = pageRank.values.max(), maxPR > 0
        else { return 16 }
        return 13 + 16 * CGFloat(value / maxPR)
    }

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: camera.pan.width, y: camera.pan.height)
            context.scaleBy(x: camera.zoom, y: camera.zoom)
            draw(in: &context)
        }
    }

    func draw(in context: inout GraphicsContext) {
        let highlighted = hovered ?? selection

        // Edges first so nodes sit on top.
        for edge in layout.edges {
            var path = Path()
            path.move(to: edge.start)
            let mid = (edge.start.y + edge.end.y) / 2
            path.addCurve(
                to: edge.end,
                control1: CGPoint(x: edge.start.x, y: mid),
                control2: CGPoint(x: edge.end.x, y: mid))

            let touches = highlighted == edge.from || highlighted == edge.to
            let color: Color = edge.isBackEdge ? .red : (touches ? .accentColor : .secondary)
            context.stroke(
                path,
                with: .color(color.opacity(touches ? 0.95 : (edge.isBackEdge ? 0.8 : 0.32))),
                style: StrokeStyle(
                    lineWidth: touches ? 2.4 : 1.3,
                    dash: edge.isBackEdge ? [5, 3] : []
                )
            )
        }

        for node in layout.nodes {
            let r = radius(for: node.id)
            let rect = CGRect(
                x: node.position.x - r, y: node.position.y - r, width: r * 2, height: r * 2)
            let issue = issuesByID[node.id]
            let isSelected = node.id == selection
            let isHovered = node.id == hovered

            context.fill(Circle().path(in: rect), with: .color(fill(for: issue)))

            if node.inCycle {
                // Cycle membership gets its own unmistakable ring.
                context.stroke(
                    Circle().path(in: rect.insetBy(dx: -3, dy: -3)),
                    with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
            }
            if isSelected || isHovered {
                context.stroke(
                    Circle().path(in: rect.insetBy(dx: -4, dy: -4)),
                    with: .color(.accentColor), lineWidth: isSelected ? 3 : 2)
            }
            if actionable.contains(node.id) {
                context.stroke(Circle().path(in: rect), with: .color(.yellow), lineWidth: 2)
            }

            let label = Text(node.id).font(.system(size: 9, weight: .medium))
            context.draw(
                context.resolve(label.foregroundStyle(.primary)),
                at: CGPoint(x: node.position.x, y: node.position.y + r + 9))
        }
    }

    private func fill(for issue: Issue?) -> Color {
        guard let issue else { return .gray }
        switch issue.status {
        case .open: return .blue
        case .inProgress: return .orange
        case .blocked: return .red
        case .review: return .purple
        case .closed: return .green.opacity(0.55)
        case .deferred, .draft: return .gray
        default: return .secondary
        }
    }

    /// Nearest node within its own radius, in canvas coordinates.
    ///
    /// Through the camera rather than repeating its arithmetic: when the two
    /// disagree, clicks land on the node that *was* under the cursor before the
    /// last zoom, which reads as the graph ignoring the click.
    func node(at point: CGPoint) -> LayoutNode? {
        let p = camera.canvasPoint(for: point)
        return layout.nodes
            .map { ($0, hypot($0.position.x - p.x, $0.position.y - p.y)) }
            .filter { $0.1 <= radius(for: $0.0.id) + 4 }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Interactive dependency graph: owns layout, camera and hit-testing, and
/// delegates all drawing to `GraphCanvas`.
struct GraphView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var layout: GraphLayout = .empty
    @State private var camera = GraphCamera()
    @State private var hovered: String?
    @State private var isLaidOut = false

    // Both continuous gestures are applied as increments — the change since the
    // last event — rather than recomputed from a camera captured at the start.
    // A pinch and a drag can run at once on a trackpad, and two gestures each
    // recomputing from their own baseline would discard each other's work; the
    // graph then jumps between two cameras while both hands are moving.
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1

    /// The pane's size, for the zoom buttons — which are drawn over the graph
    /// rather than inside the reader that measures it.
    @State private var paneSize: CGSize = .zero

    private var canvas: GraphCanvas {
        GraphCanvas(
            layout: layout,
            issuesByID: store.issuesByID,
            actionable: store.actionable,
            pageRank: store.metrics.pageRank,
            selection: store.focusedID,
            hovered: hovered,
            camera: camera
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                canvas
                    .contentShape(Rectangle())
                    // Two-finger scrolling. An overlay, so its rectangle is the
                    // canvas's; it never takes a click, so every gesture below
                    // is untouched.
                    .overlay {
                        GraphScrollCatcher { translation in
                            camera = camera.panned(by: translation)
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                camera = camera.panned(
                                    by: CGSize(
                                        width: value.translation.width - lastDragTranslation.width,
                                        height: value.translation.height
                                            - lastDragTranslation.height))
                                lastDragTranslation = value.translation
                            }
                            .onEnded { _ in lastDragTranslation = .zero }
                    )
                    // Simultaneous with the drag: a pinch that also slides is
                    // one motion to the hand, and making them exclusive means
                    // whichever the framework recognises first wins and the
                    // other half of the motion is dropped.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                guard lastMagnification > 0 else { return }
                                camera = camera.magnified(
                                    by: value.magnification / lastMagnification,
                                    around: anchor(of: value, in: geo.size))
                                lastMagnification = value.magnification
                            }
                            .onEnded { _ in lastMagnification = 1 }
                    )
                    .onTapGesture { location in
                        if let hit = canvas.node(at: location) { store.select(id: hit.id) }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = canvas.node(at: point)?.id
                        case .ended: hovered = nil
                        }
                    }
                    .onAppear {
                        paneSize = geo.size
                        camera = camera.centred(content: layout.size, in: geo.size)
                    }
                    // The buttons sit outside this reader and zoom about the
                    // middle of the pane, so the size has to be carried out to
                    // them.
                    .onChange(of: geo.size) { _, size in paneSize = size }
            }

            controls
        }
        .background(.background.secondary)
        .task(id: layoutKey) { await rebuild() }
        .overlay {
            if !isLaidOut {
                ProgressView("Laying out graph…")
            } else if layout.nodes.isEmpty {
                EmptyStateView(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "Nothing to plot",
                    message: "No beads match the current filter."
                )
            }
        }
    }

    /// Recompute only when the visible set or edges actually change.
    private var layoutKey: String {
        "\(store.visibleIssues.count)-\(store.edges.count)-\(store.query.filter.rawValue)-\(store.query.searchText)"
    }

    private func rebuild() async {
        let ids = store.visibleIssues.map(\.id)
        let edges = store.edges
        isLaidOut = false
        // Layout is pure and can be expensive, so keep it off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            GraphLayoutEngine.layout(nodes: ids, edges: edges)
        }.value
        layout = result
        isLaidOut = true
    }

    /// Where a pinch is happening, in the canvas's own coordinates.
    ///
    /// `MagnifyGesture` reports its anchor as a `UnitPoint` — a fraction of the
    /// view — so it has to be multiplied back out by the size the gesture was
    /// measured in.
    private func anchor(of value: MagnifyGesture.Value, in size: CGSize) -> CGPoint {
        CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
    }

    /// The middle of the pane, which is what the buttons zoom about.
    ///
    /// Anchoring them matters for the same reason it matters for a pinch: a
    /// step that leaves the pan alone slides the graph across the pane and off
    /// it, so zooming in twice from the buttons used to need a drag afterwards
    /// to find the nodes again. Before the pane has been measured there is
    /// nothing to anchor to, and the origin is the old behaviour.
    private var paneCentre: CGPoint {
        CGPoint(x: paneSize.width / 2, y: paneSize.height / 2)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { camera = camera.zoomed(to: camera.zoom - 0.15, around: paneCentre) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out — or pinch on a trackpad")
                Button { camera = camera.zoomed(to: camera.zoom + 0.15, around: paneCentre) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in — or pinch on a trackpad")
                Button { camera = GraphCamera() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset view")
                Text("\(Int(camera.zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !layout.cycles.isEmpty {
                Label(
                    "\(layout.cycles.count) dependency cycle\(layout.cycles.count == 1 ? "" : "s")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .padding(6)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .help(layout.cycles.map { $0.joined(separator: " → ") }.joined(separator: "\n"))
            }

            GraphLegend(hasPageRank: store.metrics.pageRank != nil)
        }
        .padding(10)
    }
}

struct GraphLegend: View {
    let hasPageRank: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Legend").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            legendRow(.blue, "Open")
            legendRow(.orange, "In progress")
            legendRow(.red, "Blocked")
            legendRow(.green.opacity(0.55), "Closed")
            HStack(spacing: 5) {
                Circle().strokeBorder(.yellow, lineWidth: 2).frame(width: 9, height: 9)
                Text("Actionable").font(.caption2)
            }
            Text(hasPageRank ? "Size = PageRank" : "Size = uniform (metrics pending)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2)
        }
    }
}
