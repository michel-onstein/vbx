import VBXAppCore
import VBXCore
import SwiftUI

/// Detail pane for the selected bead: fields, metrics with their status,
/// dependencies both ways, and comments.
struct InspectorView: View {
    @EnvironmentObject var store: ProjectStore
    /// What closing the bead releases, as the engine answered for it. Nil
    /// until it answers, and when it could not — never an empty list, which
    /// would read as "unblocks nothing".
    @State private var unblocks: [String]?

    var body: some View {
        Group {
            if let issue = store.selectedIssue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(issue)
                        Divider()
                        metrics(issue)
                        Divider()
                        dependencies(issue)
                        if !issue.description.isEmpty {
                            Divider()
                            section("Description") {
                                MarkdownText(
                                    source: issue.description,
                                    beadTitles: store.beadTitles)
                            }
                        }
                        if !issue.comments.isEmpty {
                            Divider()
                            comments(issue)
                        }
                    }
                    .padding(14)
                }
                .task(id: issue.id) {
                    // Forget the previous bead's answer first, or it shows
                    // against this one until the engine replies.
                    unblocks = nil
                    unblocks = await store.unblocks(issue.id)
                }
                // Bead links carry a vbx:// URL. Handling them here keeps the
                // click inside the app: without this the system would try to
                // launch a second vbx for the scheme.
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        guard let id = BeadURL.bead(in: url) else { return .systemAction }
                        return store.select(id: id) ? .handled : .discarded
                    })
            } else {
                EmptyStateView(
                    symbol: "sidebar.trailing",
                    title: "No bead selected",
                    message: "Select a bead to see its detail and metrics."
                )
            }
        }
    }

    private func header(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                StatusChip(status: issue.status)
            }
            Text(issue.title)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Label(issue.type.displayName, systemImage: issue.type.symbolName)
                Text("·")
                Text(issue.priorityLabel)
                if let assignee = issue.assignee, !assignee.isEmpty {
                    Text("·")
                    Text(assignee)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }

            if store.actionable.contains(issue.id) {
                Label("Actionable now — nothing is blocking this", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            // Only while the engine says the deferral still withholds the
            // bead: a date that has passed is no reason for anything, and
            // whether it has passed is decided at the engine's clock.
            if store.deferred.contains(issue.id) {
                Label(
                    DeferUntilCell.reason(issue.deferUntil),
                    systemImage: DeferUntilCell.symbol
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func metrics(_ issue: Issue) -> some View {
        section("Metrics") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Blocks").foregroundStyle(.secondary)
                    Text("\(store.metrics.blocks(issue.id))").monospacedDigit()
                }
                GridRow {
                    Text("Blocked by").foregroundStyle(.secondary)
                    Text("\(store.metrics.blockedBy(issue.id))").monospacedDigit()
                }
                GridRow {
                    Text("Unblocks").foregroundStyle(.secondary)
                    if let known = store.knownUnblocks(issue.id) ?? unblocks {
                        Text("\(known.count)").monospacedDigit()
                    } else {
                        Text(EngineReportText.absent).foregroundStyle(.tertiary)
                            .help(store.unavailableReason(.unblocks).map {
                                EngineReportText.unavailable(.unblocks, $0)
                            } ?? "")
                    }
                }
                metricRow(
                    "PageRank", value: store.metrics.pageRank?[issue.id],
                    status: store.metrics.status?.pageRank, decimals: 4)
                metricRow(
                    "Betweenness", value: store.metrics.betweenness?[issue.id],
                    status: store.metrics.status?.betweenness, decimals: 3)
                metricRow(
                    "Critical path", value: store.metrics.criticalPath?[issue.id],
                    status: store.metrics.status?.critical, decimals: 2)
            }
            .font(.callout)

            let resolved = store.knownUnblocks(issue.id) ?? unblocks ?? []
            if !resolved.isEmpty {
                Text("Closing this unblocks: \(resolved.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricRow(
        _ label: String, value: Double?, status: MetricStatusEntry?, decimals: Int
    ) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            if let value {
                Text(String(format: "%.\(decimals)f", value)).monospacedDigit()
            } else {
                Text(status?.annotation ?? "not computed")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func dependencies(_ issue: Issue) -> some View {
        let blockers = store.blockers(of: issue)
        let dependents = store.dependents(of: issue)

        section("Dependencies") {
            if blockers.isEmpty && dependents.isEmpty {
                Text("No dependencies.").font(.caption).foregroundStyle(.secondary)
            }
            if !blockers.isEmpty {
                Text("Waiting on").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(blockers, id: \.0.id) { dep, target in
                    linkRow(
                        id: dep.dependsOnID,
                        title: target?.title ?? "(not in this workspace)",
                        status: target?.status,
                        note: dep.type.isBlocking ? nil : dep.type.rawValue
                    )
                }
            }
            if !dependents.isEmpty {
                Text("Blocking").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 3)
                ForEach(dependents) { dependent in
                    linkRow(
                        id: dependent.id, title: dependent.title,
                        status: dependent.status, note: nil)
                }
            }
        }
    }

    private func linkRow(id: String, title: String, status: IssueStatus?, note: String?)
        -> some View
    {
        Button {
            store.select(id: id)
        } label: {
            HStack(spacing: 6) {
                if let status {
                    Image(systemName: status.symbolName).font(.caption2).foregroundStyle(.secondary)
                }
                Text(id).font(.caption.monospaced())
                Text(title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func comments(_ issue: Issue) -> some View {
        section("Comments (\(issue.comments.count))") {
            ForEach(issue.comments) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(comment.author).font(.caption.weight(.medium))
                        Spacer()
                        if let date = comment.createdAt {
                            Text(date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    MarkdownText(
                        source: comment.text,
                        font: .caption,
                        beadTitles: store.beadTitles)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
