import VBXAppCore
import VBXCore
import Charts
import SwiftUI

/// Label analytics: per-domain health, velocity and completion.
struct LabelsView: View {
    @EnvironmentObject var store: ProjectStore

    private var labels: [LabelHealth] {
        // Worst health first: the point of this view is to surface trouble.
        store.labelAnalysis.labels.sorted {
            $0.health != $1.health ? $0.health < $1.health : $0.label < $1.label
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LabelHealthSummary()

                if !store.labelAnalysis.attentionNeeded.isEmpty {
                    AttentionBanner(labels: store.labelAnalysis.attentionNeeded)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14
                ) {
                    ForEach(labels) { health in
                        LabelHealthCard(health: health)
                    }
                }
            }
            .padding(14)
        }
        .background(.background.secondary)
        .overlay {
            if labels.isEmpty {
                EmptyStateView(
                    symbol: "tag",
                    title: "No labels",
                    message: "No bead in this workspace carries a label."
                )
            }
        }
    }
}

struct LabelHealthSummary: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        let a = store.labelAnalysis
        HStack(spacing: 22) {
            stat("\(a.totalLabels)", "Labels", .primary)
            stat("\(a.healthyCount)", "Healthy", .green)
            stat("\(a.warningCount)", "Warning", .orange)
            stat("\(a.criticalCount)", "Critical", .red)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.monospacedDigit().weight(.medium)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct AttentionBanner: View {
    @EnvironmentObject var store: ProjectStore
    let labels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            HStack(spacing: 6) {
                ForEach(labels.prefix(8), id: \.self) { label in
                    Button {
                        store.query.labels = [label]
                        store.surface = .list
                    } label: {
                        Text(label)
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(label) in the list")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
    }
}

struct LabelHealthCard: View {
    @EnvironmentObject var store: ProjectStore
    let health: LabelHealth

    private var tint: Color {
        switch health.healthLevel {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(health.label, systemImage: health.healthLevel.symbolName)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Text("\(health.health)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .help("Composite health score, 0–100")
            }

            ProgressView(value: health.completion)
                .tint(tint)
                .help("\(health.closedCount) of \(health.issueCount) closed")

            HStack(spacing: 14) {
                metric("\(health.issueCount)", "total")
                metric("\(health.openCount)", "open")
                metric("\(health.closedCount)", "closed")
                if health.blockedCount > 0 {
                    metric("\(health.blockedCount)", "blocked", .red)
                }
            }

            if let velocity = health.velocity {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: velocity.trendSymbol)
                        .font(.caption)
                        .foregroundStyle(
                            velocity.trendDirection == "improving"
                                ? .green
                                : velocity.trendDirection == "declining" ? .red : .secondary)
                    Text("\(velocity.closedLast7Days) closed this week")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if velocity.avgDaysToClose > 0 {
                        Text("~\(Int(velocity.avgDaysToClose))d to close")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Button {
                store.showLabelInList(health.label)
            } label: {
                Text("Show in list").font(.caption)
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func metric(_ value: String, _ label: String, _ tint: Color = .primary)
        -> some View
    {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
