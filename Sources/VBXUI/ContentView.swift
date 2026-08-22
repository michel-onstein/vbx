import VBXAppCore
import VBXCore
import SwiftUI

public struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showInspector = true

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            Group {
                if let error = store.loadError {
                    EmptyStateView(
                        symbol: "exclamationmark.triangle",
                        title: "Could not open workspace",
                        message: error,
                        actionTitle: "Choose Workspace…",
                        action: store.presentOpenPanel
                    )
                } else if !store.isLoaded {
                    if store.isLoading {
                        ProgressView("Loading…").controlSize(.large)
                    } else {
                        EmptyStateView(
                            symbol: "shippingbox",
                            title: "No workspace open",
                            message: "Open a folder containing a .beads directory.",
                            actionTitle: "Choose Workspace…",
                            action: store.presentOpenPanel
                        )
                    }
                } else {
                    surfaceView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    SearchScopeBar()
                    RecipeBanner()
                    TimeTravelBanner()
                }
            }
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .searchable(text: $store.query.searchText, placement: .toolbar, prompt: "Search beads")
        .navigationTitle(store.info?.displayName ?? "vbx")
        .navigationSubtitle(subtitle)
        .background(TerminalKeyCatcher())
    }

    private var subtitle: String {
        guard let info = store.info else { return "" }
        return "\(info.issueCount) beads · \(store.actionable.count) ready"
    }

    @ViewBuilder
    private var surfaceView: some View {
        switch store.surface {
        case .list: IssueListView()
        case .board: BoardView()
        case .graph: GraphView()
        case .tree: TreeView()
        case .insights: InsightsView()
        case .plan: PlanView()
        case .labels: LabelsView()
        case .flow: FlowMatrixView()
        case .attention: AttentionView()
        case .history: HistoryView()
        case .alerts: AlertsView()
        case .sprint: SprintView()
        }
    }

    /// One tooltip per view-switcher segment, in declaration order.
    ///
    /// Built from ``ViewSurface`` rather than written out, so the tooltip, the
    /// sidebar row and the View menu cannot drift apart — they are all the same
    /// `displayName`. The shortcut rides along because the enum already carries
    /// it, and naming it teaches the key at the moment someone is reaching for
    /// the mouse instead.
    static let surfaceTooltips: [String] = ViewSurface.allCases.map { surface in
        "\(surface.displayName) (⌘\(surface.keyEquivalent.character))"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Declared before the view picker so they sit at the leading end of
        // the bar, where the same control lives in every browser and Finder.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 2) {
                Button {
                    store.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!store.canGoBack)
                // The glyph alone is not an accessible name, and a disabled
                // button gives no other clue what it would have done.
                .help("Back")

                Button {
                    store.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!store.canGoForward)
                .help("Forward")
            }
        }

        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $store.surface) {
                ForEach(ViewSurface.allCases) { surface in
                    Label(surface.displayName, systemImage: surface.symbolName).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            // Each segment names its own view. `.help` on the labels inside the
            // picker does not reach the segments — see ``SegmentTooltips`` —
            // and with `.iconOnly` the glyph is otherwise the only clue what a
            // segment does.
            .background { SegmentTooltips(tooltips: Self.surfaceTooltips) }
        }

        ToolbarItem {
            Picker("Filter", selection: $store.query.filter) {
                ForEach(IssueFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .help("Filter beads")
        }

        ToolbarItem {
            Menu {
                // The named orderings only. Every column ordering is reachable
                // from its header, and listing all of them here would bury
                // these.
                Picker("Sort", selection: $store.query.sort) {
                    ForEach(SortMode.cycleCases) { mode in
                        Text(mode.displayName)
                            // Sorting by a metric that has not been computed
                            // would silently order by zeros, so it stays
                            // disabled until Phase 2 lands.
                            .disabled(mode.requiresPhase2 && !store.metrics.hasPhase2Values)
                            .tag(mode)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort order")
        }

        ToolbarItem {
            RevisionScrubber()
        }

        ToolbarItem {
            Button {
                Task { await store.reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(!store.isLoaded || store.isLoading)
            .help("Reload from disk")
        }

        ToolbarItem {
            TutorialLink()
        }

        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle inspector")
        }
    }
}

/// Reusable placeholder for the empty and error states.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Bottom status strip: counts, Phase-2 progress, source and data hash.
struct StatusBar: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        HStack(spacing: 14) {
            if let info = store.info {
                Label("\(info.issueCount)", systemImage: "circle.grid.2x2")
                    .help("Beads loaded")
                Label("\(store.actionable.count) ready", systemImage: "bolt.circle")
                    .help("Actionable: no unresolved blocking dependency")
                Label(
                    "\(store.metrics.nodeCount) nodes · \(store.metrics.edgeCount) edges",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                phase2Indicator

                // Colour alone is not an affordance, and tinted rows can be
                // scrolled off screen. The count says the same thing in one
                // place, and says nothing at all when there is no repository to
                // compare against — which is not the same as nothing pending.
                if store.dirtyBeads.isKnown, store.dirtyBeads.total > 0 {
                    Label(
                        "\(store.dirtyBeads.total) uncommitted",
                        systemImage: "pencil.circle"
                    )
                    .help(uncommittedSummary)
                }

                if store.isWatching {
                    Label("watching", systemImage: "dot.radiowaves.left.and.right")
                        .help("Live reload is on; changes to \(info.source) reload automatically")
                }

                Spacer()

                Text(info.kind.displayName)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Text(info.shortHash)
                    .monospaced()
                    .help("Data hash — matches bv's for the same input")
            } else {
                Text("No workspace").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Spells out the three kinds, because "7 uncommitted" does not say whether
    /// anything was deleted — and a deletion has no row to notice.
    private var uncommittedSummary: String {
        let state = store.dirtyBeads
        var parts: [String] = []
        if !state.changed.isEmpty { parts.append("\(state.changed.count) modified") }
        if !state.added.isEmpty { parts.append("\(state.added.count) added") }
        if !state.removed.isEmpty { parts.append("\(state.removed.count) removed") }
        return parts.joined(separator: ", ") + " since the last commit"
    }

    @ViewBuilder
    private var phase2Indicator: some View {
        if store.phase2InFlight {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("computing metrics…")
            }
        } else if store.metrics.hasPhase2Values {
            Label("metrics ready", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else if store.isLoaded {
            Button {
                Task { await store.computePhase2() }
            } label: {
                Label("compute metrics", systemImage: "play.circle")
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}
