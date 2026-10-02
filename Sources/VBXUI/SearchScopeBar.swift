import VBXAppCore
import VBXCore
import SwiftUI

/// The search scope bar: which ranking, and with what weights.
///
/// Shown only while there is a query, because a scope bar over an empty search
/// is a control with nothing to scope.
struct SearchScopeBar: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showingWeights = false

    private var hasQuery: Bool {
        !store.query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if hasQuery {
            HStack(spacing: 10) {
                Picker("Ranking", selection: $store.searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(store.searchMode.explanation)

                if store.searchMode == .hybrid,
                    let reason = store.unavailableReason(.searchPresets)
                {
                    unavailable(.searchPresets, reason)
                } else if store.searchMode == .hybrid {
                    Picker("Preset", selection: $store.searchPreset) {
                        ForEach(store.searchPresets.presets) { preset in
                            Text(preset.displayName).tag(preset.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 170)
                    .disabled(store.searchWeights != nil)

                    Button {
                        // Start from the current preset, so adjusting is a
                        // tweak rather than a blank slate.
                        if store.searchWeights == nil {
                            store.searchWeights =
                                store.searchPresets.weights(named: store.searchPreset)
                                ?? SearchWeights()
                        }
                        showingWeights = true
                    } label: {
                        Label("Weights", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingWeights, arrowEdge: .bottom) {
                        WeightsEditor()
                            .environmentObject(store)
                    }

                    if store.searchWeights != nil {
                        Button("Reset") { store.searchWeights = nil }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }

                if store.searchInFlight {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                if store.searchMode == .hybrid, let reason = store.unavailableReason(.search) {
                    // The list falls back to the fuzzy ranking, which is
                    // still a ranking — so say this is not the one chosen.
                    unavailable(.search, reason)
                } else if store.isUsingEngineSearch {
                    Text(
                        "\(store.searchResults.results.count) of "
                            + "\(store.searchResults.totalBeads) · \(store.searchResults.provider)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))
            .overlay(alignment: .bottom) { Divider() }
            .task { await store.loadSearchPresets() }
            // Re-ranking is a round trip, so it happens when the inputs
            // settle rather than on every keystroke.
            .onChange(of: store.query.searchText) { Task { await store.runEngineSearch() } }
            .onChange(of: store.searchMode) { Task { await store.runEngineSearch() } }
            .onChange(of: store.searchPreset) { Task { await store.runEngineSearch() } }
        }
    }

    /// One line, because the bar is one line high: the title, the reason as
    /// its tooltip, and the retry.
    private func unavailable(_ report: EngineReport, _ reason: String) -> some View {
        HStack(spacing: 6) {
            Label(EngineReportText.title(report), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Try Again") { Task { await store.retry(report) } }
                .buttonStyle(.link)
                .font(.caption)
        }
        .help(EngineReportText.unavailable(report, reason))
    }
}

/// Live weight sliders for hybrid ranking.
struct WeightsEditor: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ranking weights").font(.headline)
            Text("Relative importance of each factor. Re-ranks as you adjust.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let weights = store.searchWeights {
                ForEach(weights.factors, id: \.name) { factor in
                    HStack(spacing: 8) {
                        Text(factor.name)
                            .font(.caption)
                            .frame(width: 78, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { store.searchWeights?[keyPath: factor.key] ?? 0 },
                                set: { value in
                                    store.searchWeights?[keyPath: factor.key] = value
                                    Task { await store.runEngineSearch() }
                                }
                            ), in: 0...1)
                        Text(String(format: "%.2f", factor.value))
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                // The engine normalises, so the total is informational — but
                // showing it explains why moving one slider changes the rest.
                Text(String(format: "Total %.2f — normalised before ranking", weights.total))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Use preset") { store.searchWeights = nil }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// Why a hybrid result ranked where it did.
struct SearchScoreBreakdown: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Score").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.3f", hit.score)).font(.caption.monospacedDigit())
            }
            ForEach(hit.contributions, id: \.name) { contribution in
                HStack {
                    Text(contribution.name).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.3f", contribution.value))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
    }
}
