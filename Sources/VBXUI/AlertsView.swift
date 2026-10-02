import VBXAppCore
import VBXCore
import SwiftUI

/// Proactive health warnings, grouped by severity.
///
/// Alerts come in two kinds and the panel says which you are getting: without
/// a saved baseline only the issue-derived checks can fire, because the delta
/// checks have nothing to compare against.
struct AlertsView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var savingBaseline = false
    @State private var baselineDescription = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let reason = store.unavailableReason(.alerts) {
                // Never "No alerts": nothing was checked.
                UnavailableReportView(report: .alerts, reason: reason)
            } else if store.alerts.alerts.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.shield",
                    title: "No alerts",
                    message: store.alerts.hasBaseline
                        ? "Nothing has drifted since the baseline was saved."
                        : "Nothing looks wrong. Save a baseline to also catch drift over time."
                )
            } else {
                list
            }
        }
        .sheet(isPresented: $savingBaseline) { baselineSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Alerts").font(.headline)
                Spacer()
                if store.unavailableReason(.alerts) == nil {
                    severityCount(.critical, store.alerts.summary.critical)
                    severityCount(.warning, store.alerts.summary.warning)
                    severityCount(.info, store.alerts.summary.info)
                }
            }

            baselineRow
            filters
        }
        .padding(12)
    }

    private var baselineRow: some View {
        HStack(spacing: 8) {
            if let reason = store.unavailableReason(.baseline) {
                // Not "No baseline": whether one is saved is unknown.
                UnavailableReportLabel(report: .baseline, reason: reason)
            } else if store.baseline.exists {
                Image(systemName: "flag.checkered").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(
                        store.baseline.description.isEmpty
                            ? "Baseline saved" : store.baseline.description
                    )
                    .font(.caption)
                    if let created = store.baseline.createdAt {
                        Text(created, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !store.baseline.commitSHA.isEmpty {
                    Text(store.baseline.shortSHA)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "flag.slash").foregroundStyle(.secondary)
                Text("No baseline — drift alerts are unavailable until one is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Notify", isOn: $store.notifyOnCriticalAlerts)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Deliver new critical alerts as notifications while watching")

            Button(store.baseline.exists ? "Update baseline" : "Save baseline") {
                baselineDescription = ""
                savingBaseline = true
            }
            .controlSize(.small)
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Severity", selection: $store.alertSeverityFilter) {
                Text("All severities").tag(AlertSeverity?.none)
                ForEach(AlertSeverity.allCases) { severity in
                    Text(severity.displayName).tag(AlertSeverity?.some(severity))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 150)

            Picker("Type", selection: $store.alertTypeFilter) {
                Text("All types").tag(String?.none)
                ForEach(store.alerts.types, id: \.self) { type in
                    Label(
                        HealthAlert.displayName(forType: type),
                        systemImage: HealthAlert.symbolName(forType: type)
                    )
                    .tag(String?.some(type))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 180)

            Picker("Label", selection: $store.alertLabelFilter) {
                Text("All labels").tag(String?.none)
                ForEach(store.alerts.labels, id: \.self) { label in
                    Text(label).tag(String?.some(label))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 150)

            Spacer()
        }
        // Filtering happens in the engine, so changing one re-runs the check
        // rather than hiding rows the engine still counts.
        .onChange(of: store.alertSeverityFilter) { Task { await store.refreshAlerts() } }
        .onChange(of: store.alertTypeFilter) { Task { await store.refreshAlerts() } }
        .onChange(of: store.alertLabelFilter) { Task { await store.refreshAlerts() } }
    }

    private func severityCount(_ severity: AlertSeverity, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: severity.symbolName).font(.caption2)
            Text("\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(count > 0 ? tint(severity) : Color.secondary)
        .help("\(count) \(severity.displayName.lowercased())")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(store.alerts.grouped, id: \.severity) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            "\(group.severity.displayName) (\(group.alerts.count))",
                            systemImage: group.severity.symbolName
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint(group.severity))

                        ForEach(group.alerts) { alert in
                            AlertRow(alert: alert) { id in
                                store.select(id: id)
                                store.surface = .list
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var baselineSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save baseline").font(.headline)
            Text(
                "Drift is measured from this point. Saving again replaces the previous baseline."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("What is this baseline?", text: $baselineDescription)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { savingBaseline = false }
                Button("Save") {
                    let description = baselineDescription
                    savingBaseline = false
                    Task { await store.saveBaseline(description: description) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func tint(_ severity: AlertSeverity) -> Color { severity.tint }
}

extension AlertSeverity {
    var tint: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

/// One alert: what is wrong, which beads, and bv's suggested remedy.
///
/// Its own view, rather than a method on the panel, so a snapshot can render
/// one alert at a known size and measure where its lines land.
struct AlertRow: View {
    let alert: HealthAlert
    /// Selects a bead in the list. The alert's bead and its related bead both
    /// go through it, so the two links cannot navigate differently.
    var open: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(alert.message).font(.callout)
                Spacer(minLength: 8)
                Label(alert.typeDisplayName, systemImage: alert.typeSymbolName)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }

            HStack(spacing: 10) {
                if !alert.issueID.isEmpty {
                    beadLink(alert.issueID)
                }
                if !alert.relatedIssueID.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        beadLink(alert.relatedIssueID)
                    }
                    .help("Related bead")
                }
                ForEach(alert.allLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                // Shown only when there is a real before-and-after; a zero
                // delta on an issue-derived alert is the absence of a
                // measurement, not a measurement of zero.
                if alert.hasDelta {
                    Text(
                        String(
                            format: "%.3f → %.3f", alert.baselineValue, alert.currentValue)
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if alert.unblocksCount > 0 {
                    Text("unblocks \(alert.unblocksCount)")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
            }

            ForEach(alert.details, id: \.self) { detail in
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }

            // Last, because it is the answer to everything above it. bv's text
            // is shown verbatim and selectable — it is advice, never run.
            if let action = alert.suggestedAction {
                Label {
                    Text(action).textSelection(.enabled)
                } icon: {
                    Image(systemName: "lightbulb")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alert.severity.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func beadLink(_ id: String) -> some View {
        Button {
            open(id)
        } label: {
            Text(id).font(.caption.monospaced())
        }
        .buttonStyle(.link)
    }
}
