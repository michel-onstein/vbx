import VBXAppCore
import VBXCore
import Charts
import SwiftUI

/// Sprint dashboard: burndown against the ideal, and what the remaining work
/// costs with more hands on it.
struct SprintView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let reason = store.unavailableReason(.sprints) {
                    // Not "No sprints defined": whether any are is what the
                    // failed read would have said.
                    UnavailableReportLabel(report: .sprints, reason: reason)
                } else if store.burndown.isLoaded {
                    riskBanner
                    atRiskSection
                    burndownChart
                    scopeChangesSection
                    velocityChart
                } else {
                    noSprint
                }
                Divider()
                capacitySection
            }
            .padding(16)
        }
        .task { await store.loadSprints() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Sprint").font(.headline)
            Spacer()
            if !store.sprints.sprints.isEmpty {
                Picker("Sprint", selection: $store.selectedSprintID) {
                    Text("Current").tag("")
                    ForEach(store.sprints.sprints) { sprint in
                        Text(sprint.displayName).tag(sprint.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
                .onChange(of: store.selectedSprintID) { Task { await store.loadSprints() } }
            }
        }
    }

    @ViewBuilder
    private var noSprint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.sprints.sprints.isEmpty {
                Label("No sprints defined", systemImage: "calendar.badge.exclamationmark")
                    .font(.callout)
                Text("Add sprints to this workspace's `.beads` directory to see a burndown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("No sprint selected", systemImage: "calendar")
                    .font(.callout)
                // The commonest case: sprints exist but none spans today.
                Text(store.sprintError ?? "Choose a sprint above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var riskBanner: some View {
        let burndown = store.burndown
        return HStack(spacing: 12) {
            Image(systemName: burndown.onTrack ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(burndown.onTrack ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(burndown.sprintName.isEmpty ? burndown.sprintID : burndown.sprintName)
                    .font(.callout.weight(.medium))
                Text(burndown.verdict).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            stat("\(burndown.completedIssues)/\(burndown.totalIssues)", "closed")
            stat("\(burndown.elapsedDays)/\(burndown.totalDays)", "days")
            // Ahead-or-behind is the number people actually want, and it is
            // absent rather than zero before the sprint starts.
            if let ahead = burndown.aheadBy {
                stat(
                    ahead >= 0 ? "+\(ahead)" : "\(ahead)",
                    ahead >= 0 ? "ahead" : "behind",
                    tint: ahead >= 0 ? .green : .orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (store.burndown.onTrack ? Color.green : Color.orange).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private var atRiskSection: some View {
        SprintAtRiskSection(items: store.burndown.atRisk) { store.select(id: $0) }
    }

    /// Beads that joined or left after the sprint was planned — the reason
    /// the ideal line bends.
    @ViewBuilder
    private var scopeChangesSection: some View {
        if !store.burndown.scopeChanges.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scope changes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(store.burndown.scopeChanges) { change in
                    HStack(spacing: 6) {
                        Image(systemName: change.isAddition ? "plus.circle" : "minus.circle")
                            .foregroundStyle(change.isAddition ? Color.orange : Color.green)
                            .font(.caption)
                        Text(change.date, style: .date).font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            store.select(id: change.issueID)
                        } label: {
                            Text(change.issueID).font(.caption.monospaced())
                        }
                        .buttonStyle(.link)
                        Text(change.issueTitle).font(.caption).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ name: String, tint: Color = .primary) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(tint)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var burndownChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Burndown").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart {
                // The ideal first, so the actual line draws over it.
                ForEach(store.burndown.idealLine) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Remaining", point.remaining),
                        series: .value("Series", "Ideal")
                    )
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(store.burndown.dailyPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Remaining", point.remaining),
                        series: .value("Series", "Actual")
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbol(.circle)
                }
            }
            .chartYAxisLabel("Beads remaining")
            .chartForegroundStyleScale([
                "Ideal": Color.secondary, "Actual": Color.accentColor,
            ])
            .frame(height: 220)
        }
    }

    private var velocityChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Closed per day").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(dailyClosures, id: \.date) { entry in
                BarMark(
                    x: .value("Date", entry.date, unit: .day),
                    y: .value("Closed", entry.closed)
                )
                .foregroundStyle(Color.accentColor.opacity(0.7))
                // The required pace, so the bars have something to beat.
                RuleMark(y: .value("Ideal", store.burndown.idealBurnRate))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(height: 140)
        }
    }

    /// Per-day closures, derived from the cumulative burndown.
    ///
    /// The engine reports cumulative completion; the difference between
    /// consecutive days is what closed that day.
    private var dailyClosures: [(date: Date, closed: Int)] {
        let points = store.burndown.dailyPoints
        guard !points.isEmpty else { return [] }
        var out: [(date: Date, closed: Int)] = []
        var previous = 0
        for point in points {
            out.append((point.date, max(point.completed - previous, 0)))
            previous = point.completed
        }
        return out
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Capacity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Stepper(
                    "\(store.capacityAgents) agent\(store.capacityAgents == 1 ? "" : "s")",
                    value: $store.capacityAgents, in: 1...16
                )
                .fixedSize()
                .onChange(of: store.capacityAgents) { Task { await store.loadCapacity() } }
            }

            if let reason = store.unavailableReason(.capacity) {
                UnavailableReportLabel(report: .capacity, reason: reason)
            } else {
                capacityFigures
            }
        }
    }

    private var capacityFigures: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                stat(days(store.capacity.estimatedDays), "with \(store.capacity.agents)")
                stat(days(store.capacity.totalDays), "with 1")
                stat("\(store.capacity.openIssueCount)", "open")
                stat(
                    String(format: "%.0f%%", store.capacity.parallelizablePct),
                    "parallelisable")
                Spacer()
            }

            if !store.capacity.criticalPath.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Longest dependent run — no number of agents beats this")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(Array(store.capacity.criticalPath.enumerated()), id: \.offset) {
                            index, id in
                            if index > 0 {
                                Image(systemName: "arrow.right").font(.system(size: 7))
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                store.select(id: id)
                            } label: {
                                Text(id).font(.caption2.monospaced())
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            if !store.capacity.bottlenecks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bottlenecks").font(.caption2).foregroundStyle(.secondary)
                    ForEach(store.capacity.bottlenecks) { bottleneck in
                        HStack(spacing: 6) {
                            Button {
                                store.select(id: bottleneck.id)
                            } label: {
                                Text(bottleneck.id).font(.caption.monospaced())
                            }
                            .buttonStyle(.link)
                            Text(bottleneck.title).font(.caption).lineLimit(1)
                            Spacer()
                            Text("blocks \(bottleneck.blocksCount)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func days(_ value: Double) -> String {
        value < 1 ? String(format: "%.1fd", value) : String(format: "%.0fd", value)
    }
}

/// The sprint beads the engine's at-risk detector flags, and why.
///
/// Three states, not two: `nil` — the engine did not report the detector —
/// draws nothing at all, while an empty list is the real answer "nothing is
/// at risk" and says so.
struct SprintAtRiskSection: View {
    let items: [AtRiskItem]?
    var select: (String) -> Void = { _ in }

    var body: some View {
        if let items {
            VStack(alignment: .leading, spacing: 4) {
                Text("At risk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if items.isEmpty {
                    Label("No open sprint bead is at risk.", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ item: AtRiskItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    select(item.id)
                } label: {
                    Text(item.id).font(.caption.monospaced())
                }
                .buttonStyle(.link)
                Text("P\(item.priority)").font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(item.title).font(.caption).lineLimit(1)
                Spacer()
                ForEach(item.signals, id: \.self) { signal in
                    Text(AtRiskItem.label(for: signal))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
