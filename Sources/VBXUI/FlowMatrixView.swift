import VBXAppCore
import VBXCore
import SwiftUI

/// Cross-label dependency heat map.
///
/// Each cell is "how much does the row label block the column label". Clicking
/// one filters the list to the beads behind it; the drilldown below names the
/// individual dependencies rather than leaving the number unexplained.
struct FlowMatrixView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var selectedCell: Cell?

    private struct Cell: Equatable {
        let from: String
        let to: String
    }

    private var flow: LabelFlow { store.labelFlow }

    var body: some View {
        matrixOrEmpty.reportAvailability(.labelFlow)
    }

    @ViewBuilder
    private var matrixOrEmpty: some View {
        if flow.labels.isEmpty {
            EmptyStateView(
                symbol: "square.grid.3x3",
                title: "No cross-label flow",
                message: "This workspace has no blocking dependencies between labels."
            )
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    matrix
                    if let cell = selectedCell { drilldown(cell) }
                }
                .padding(16)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cross-label flow").font(.headline)
            Text(
                "\(flow.totalCrossLabelDeps) dependencies cross a label boundary. "
                    + "A cell is how much the row label blocks the column label."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if !flow.bottleneckLabels.isEmpty {
                HStack(spacing: 5) {
                    Text("Bottlenecks").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(flow.bottleneckLabels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
    }

    private var matrix: some View {
        Grid(alignment: .center, horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                // Corner cell: the row header column's own header.
                Text("blocks →")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 108, alignment: .trailing)
                ForEach(flow.labels, id: \.self) { label in
                    Text(label)
                        .font(.caption2)
                        .lineLimit(1)
                        .rotationEffect(.degrees(-45))
                        .frame(width: 38, height: 44)
                }
            }
            ForEach(Array(flow.labels.enumerated()), id: \.offset) { rowIndex, rowLabel in
                GridRow {
                    Text(rowLabel)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 108, alignment: .trailing)
                    ForEach(Array(flow.labels.enumerated()), id: \.offset) { columnIndex, colLabel
                        in
                        cell(row: rowIndex, column: columnIndex, from: rowLabel, to: colLabel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(row: Int, column: Int, from: String, to: String) -> some View {
        let count = flow.count(from: row, to: column) ?? 0
        let isDiagonal = row == column
        let isSelected = selectedCell == Cell(from: from, to: to)

        Button {
            guard !isDiagonal, count > 0 else { return }
            let cell = Cell(from: from, to: to)
            selectedCell = selectedCell == cell ? nil : cell
            // Filtering to both labels is what makes the cell actionable:
            // the list then shows exactly the beads the number counts.
            store.query.labels = [from, to]
            store.surface = .flow
        } label: {
            Text(isDiagonal ? "·" : (count == 0 ? "" : "\(count)"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(count > 0 && !isDiagonal ? .white : .secondary)
                .frame(width: 38, height: 26)
                .background(background(count: count, isDiagonal: isDiagonal))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(isDiagonal ? "\(from)" : "\(from) blocks \(to): \(count)")
    }

    /// Colour scales with the cell's share of the largest off-diagonal count.
    ///
    /// The diagonal is excluded from the scale — a label depending on itself
    /// is not flow between labels, and letting it set the maximum would wash
    /// out every cell that is.
    private func background(count: Int, isDiagonal: Bool) -> some ShapeStyle {
        guard !isDiagonal, count > 0 else {
            return AnyShapeStyle(.quaternary.opacity(isDiagonal ? 0.25 : 0.12))
        }
        let peak = max(flow.peakCount, 1)
        let intensity = 0.25 + 0.75 * (Double(count) / Double(peak))
        return AnyShapeStyle(Color.accentColor.opacity(intensity))
    }

    @ViewBuilder
    private func drilldown(_ cell: Cell) -> some View {
        let deps = flow.dependencies(from: cell.from, to: cell.to)
        VStack(alignment: .leading, spacing: 7) {
            Text("\(cell.from) → \(cell.to)").font(.headline)
            if deps.isEmpty {
                Text("No individual dependencies recorded for this pair.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(deps) { dep in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(dep.issueCount) blocking dependencies")
                        .font(.caption.weight(.medium))
                    ForEach(dep.issueIDs, id: \.self) { id in
                        Button {
                            store.select(id: id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(id).font(.caption.monospaced())
                                Text(store.issuesByID[id]?.title ?? "(not in this workspace)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}
