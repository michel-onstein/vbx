import VBXAppCore
import VBXCore
import SwiftUI

/// Labels ranked by how much attention they need.
///
/// The ranking is only half of it. bv's score is
/// `(centrality × staleness × block impact) / velocity`, and each factor is
/// shown beside the total — a rank alone says a label is in trouble without
/// saying which lever moved it.
struct AttentionView: View {
    @EnvironmentObject var store: ProjectStore

    private var attention: LabelAttention { store.labelAttention }

    var body: some View {
        rankingOrEmpty.reportAvailability(.labelAttention)
    }

    @ViewBuilder
    private var rankingOrEmpty: some View {
        if attention.labels.isEmpty {
            EmptyStateView(
                symbol: "exclamationmark.bubble",
                title: "No attention scores",
                message: "This workspace has no labelled beads to rank."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    ForEach(attention.labels) { score in
                        row(score)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Attention").font(.headline)
            Text(
                "\(attention.totalLabels) labels ranked by "
                    + "(centrality × staleness × block impact) ÷ velocity."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ score: LabelAttentionScore) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(score.rank)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(score.label).font(.callout.weight(.medium))
                Spacer()
                Text(String(format: "%.3f", score.attentionScore))
                    .font(.callout.monospacedDigit())
            }

            // The normalised score is what makes two labels comparable; the
            // raw score's magnitude depends on the workspace.
            ProgressView(value: min(max(score.normalizedScore, 0), 1))
                .tint(tint(score.normalizedScore))

            HStack(spacing: 14) {
                ForEach(score.factors, id: \.name) { factor in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(
                                systemName: factor.raises
                                    ? "arrow.up.forward" : "arrow.down.forward"
                            )
                            .font(.system(size: 8))
                            .foregroundStyle(factor.raises ? .orange : .green)
                            Text(factor.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(String(format: "%.3f", factor.value))
                            .font(.caption.monospacedDigit())
                    }
                }
                Spacer()
                counts(score)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            // Scoping the list to the label is the action a high rank implies.
            store.query.labels = [score.label]
            store.surface = .list
        }
    }

    private func counts(_ score: LabelAttentionScore) -> some View {
        HStack(spacing: 10) {
            countChip("open", score.openCount, .blue)
            countChip("blocked", score.blockedCount, .red)
            countChip("stale", score.staleCount, .orange)
        }
    }

    private func countChip(_ name: String, _ value: Int, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)").font(.caption.monospacedDigit())
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(value > 0 ? 0.15 : 0.06), in: Capsule())
    }

    private func tint(_ normalized: Double) -> Color {
        switch normalized {
        case ..<0.34: .green
        case ..<0.67: .orange
        default: .red
        }
    }
}
