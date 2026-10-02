import VBXAppCore
import VBXCore
import SwiftUI

/// The revision scrubber, in the toolbar.
///
/// Offers the commits that actually changed the beads file, plus a free-text
/// field for anything else git understands. Selecting one puts the app into
/// time travel; the banner below the toolbar says so, because a list showing
/// badges without saying why is a list that looks wrong.
struct RevisionScrubber: View {
    @EnvironmentObject var store: ProjectStore
    @State private var custom = ""

    var body: some View {
        Menu {
            if store.isTimeTravelling {
                Button {
                    store.returnToNow()
                } label: {
                    Label("Return to now", systemImage: "arrow.uturn.forward")
                }
                Divider()
            }

            ForEach(store.revisions.revisions) { revision in
                Button {
                    Task { await store.travel(to: revision.sha) }
                } label: {
                    // The short SHA leads because it is what identifies the
                    // point; the subject explains it.
                    Text("\(revision.shortSHA)  \(revision.subject)")
                }
            }

            if let reason = store.unavailableReason(.revisions) {
                // A menu draws text and buttons only, so the compact label is
                // spelled out: the title with its reason, and the retry.
                Text(EngineReportText.unavailable(.revisions, reason))
                Button("Try Again") { Task { await store.retry(.revisions) } }
            } else if store.revisions.revisions.isEmpty {
                Text("No bead-changing commits found").foregroundStyle(.secondary)
            }
        } label: {
            Label(
                store.isTimeTravelling ? store.timeTravel.shortRevision : "Compare",
                systemImage: "clock.arrow.2.circlepath")
        }
        .help("Compare the current beads against an earlier revision")
        .task { await store.loadRevisions() }
    }
}

/// The banner shown while time travelling.
struct TimeTravelBanner: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        if store.isTimeTravelling {
            let summary = store.timeTravel.diff.summary
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Comparing against \(store.timeTravel.shortRevision)")
                        .font(.caption.weight(.medium))
                    // The requested expression is shown beside the resolved
                    // commit, never instead of it.
                    if store.timeTravel.requestedRevision != store.timeTravel.resolvedRevision,
                        !store.timeTravel.requestedRevision.isEmpty
                    {
                        Text("from \(store.timeTravel.requestedRevision)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().frame(height: 18)

                if store.timeTravel.hasChanges {
                    change("new", summary.issuesAdded, .green)
                    change("closed", summary.issuesClosed, .blue)
                    change("reopened", summary.issuesReopened, .purple)
                    change("modified", summary.issuesModified, .orange)
                    change("removed", summary.issuesRemoved, .red)
                    if summary.cyclesIntroduced > 0 {
                        change("new cycles", summary.cyclesIntroduced, .red)
                    }
                    if summary.cyclesResolved > 0 {
                        change("cycles fixed", summary.cyclesResolved, .green)
                    }
                    Label(summary.healthTrend, systemImage: summary.trendSymbol)
                        .font(.caption)
                        .foregroundStyle(trendColour(summary.healthTrend))
                } else {
                    Text("Nothing changed since then.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Return to now") { store.returnToNow() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// A count, hidden when it is zero.
    ///
    /// Zeros here would fill the banner with noise about things that did not
    /// happen; the interesting part is what did.
    @ViewBuilder
    private func change(_ name: String, _ count: Int, _ tint: Color) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Text("\(count)").font(.caption.monospacedDigit().weight(.medium))
                Text(name).font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(tint)
        }
    }

    private func trendColour(_ trend: String) -> Color {
        switch trend {
        case "improving": .green
        case "degrading": .red
        default: .secondary
        }
    }
}

/// What happened to a bead since the chosen revision.
struct DiffBadgeView: View {
    let badge: DiffBadge

    var body: some View {
        Text(badge.displayName)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint, in: RoundedRectangle(cornerRadius: 3))
            .help("\(badge.displayName.capitalized) since the compared revision")
    }

    private var tint: Color {
        switch badge {
        case .new: .green
        case .closed: .blue
        case .reopened: .purple
        case .modified: .orange
        case .removed: .red
        }
    }
}
