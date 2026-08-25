import VBXAppCore
import VBXCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        List {
            SidebarViewsSection()
            SidebarReposSection()
            SidebarFiltersSection()
            SidebarRecipesSection()
            SidebarLabelsSection()
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let warnings = store.info?.warnings, !warnings.isEmpty {
                WarningsBadge(warnings: warnings)
            }
        }
    }
}

private struct SidebarViewsSection: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Section("Views") {
            ForEach(store.availableSurfaces) { surface in
                Button {
                    store.surface = surface
                } label: {
                    HStack {
                        Label(surface.displayName, systemImage: surface.symbolName)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.surface == surface ? Color.accentColor : .primary)
            }
        }
    }
}

private struct SidebarFiltersSection: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Section("Filters") {
            ForEach(IssueFilter.allCases) { filter in
                FilterRow(filter: filter, count: count(for: filter))
            }
        }
    }

    private func count(for filter: IssueFilter) -> Int {
        var q = store.query
        q.filter = filter
        q.searchText = ""
        q.labels = []
        return q.apply(to: store.issues, actionable: store.actionable).count
    }
}

private struct FilterRow: View {
    @EnvironmentObject var store: ProjectStore
    let filter: IssueFilter
    let count: Int

    private var isActive: Bool { store.query.filter == filter }

    var body: some View {
        Button {
            store.query.filter = filter
        } label: {
            HStack {
                Label(filter.displayName, systemImage: filter.symbolName)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary)
    }
}

private struct SidebarLabelsSection: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        let counts = store.labelCounts
        if !counts.isEmpty {
            Section("Labels") {
                ForEach(counts.prefix(20), id: \.label) { entry in
                    LabelRow(label: entry.label, count: entry.count)
                }
                if !store.query.labels.isEmpty {
                    Button("Clear label filter") { store.query.labels.removeAll() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

private struct LabelRow: View {
    @EnvironmentObject var store: ProjectStore
    let label: String
    let count: Int

    private var isOn: Bool { store.query.labels.contains(label) }

    var body: some View {
        Button {
            // Through the store rather than writing `query.labels` here: the
            // toggle also clears an active recipe, because a recipe owns the
            // filter wholesale and one the user has since edited by hand is no
            // longer the recipe's. Writing the set directly skipped that, so
            // the sidebar left the sidebar claiming a recipe that no longer
            // described the screen. It was the pill's gesture that used this
            // before; the pill now edits labels instead (vbx-dot), and the
            // behaviour belongs with the control that remains.
            store.toggleLabelFilter(label)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(label).lineLimit(1)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Surfaces loader warnings rather than hiding them — a skipped malformed line
/// silently changes the graph, so the user needs to know it happened.
struct WarningsBadge: View {
    let warnings: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                Label(
                    "\(warnings.count) load warning\(warnings.count == 1 ? "" : "s")",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(warnings.prefix(8).enumerated()), id: \.offset) { _, warning in
                    Text("• \(warning)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
