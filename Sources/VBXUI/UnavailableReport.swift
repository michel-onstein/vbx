import VBXAppCore
import SwiftUI

/// The words every unavailable state uses, so a count, a pane and a tooltip
/// say the same thing.
enum EngineReportText {
    /// A count the engine could not produce. Not zero: zero is a claim about
    /// the workspace, and a failed report made none.
    static let absent = "—"

    static func title(_ report: EngineReport) -> String {
        "\(report.displayName) unavailable"
    }

    static func unavailable(_ report: EngineReport, _ reason: String) -> String {
        "\(title(report)): \(reason)"
    }
}

extension ProjectStore {
    /// `value`, or a dash while `report` is unavailable.
    func display(_ value: @autoclosure () -> String, from report: EngineReport) -> String {
        unavailableReason(report) == nil ? value() : EngineReportText.absent
    }
}

/// A whole pane standing in for a report the engine could not build: what is
/// missing, why, and a way to ask again.
///
/// Drawn instead of the pane's own empty state, which is a claim — "No
/// alerts", "No labels" — the failed report never made.
struct UnavailableReportView: View {
    @EnvironmentObject var store: ProjectStore
    let report: EngineReport
    let reason: String
    /// Asks again. Defaults to ``ProjectStore/retry(_:)``; a report read for
    /// one bead or path passes its own, because only the view knows which.
    var retry: (() async -> Void)?

    var body: some View {
        EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: EngineReportText.title(report),
            message: reason,
            actionTitle: "Try Again",
            action: { Task { await again() } }
        )
    }

    private func again() async {
        if let retry { await retry() } else { await store.retry(report) }
    }
}

/// The compact form of ``UnavailableReportView``, for a panel, a sidebar
/// section, a bar or a menu: the same three things in a line or two.
struct UnavailableReportLabel: View {
    @EnvironmentObject var store: ProjectStore
    let report: EngineReport
    let reason: String
    var retry: (() async -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(EngineReportText.title(report), systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await again() } }
                .buttonStyle(.link)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(EngineReportText.unavailable(report, reason))
    }

    private func again() async {
        if let retry { await retry() } else { await store.retry(report) }
    }
}

/// Replaces a pane with its report's unavailable state while the report is
/// unavailable. See ``View/reportAvailability(_:)``.
private struct ReportAvailability: ViewModifier {
    @EnvironmentObject var store: ProjectStore
    let report: EngineReport

    func body(content: Content) -> some View {
        if let reason = store.unavailableReason(report) {
            UnavailableReportView(report: report, reason: reason)
        } else {
            content
        }
    }
}

extension View {
    /// Shows this pane only while `report` is available, and the report's
    /// unavailable state in its place otherwise — never the pane's own empty
    /// state, which would claim the report is empty.
    func reportAvailability(_ report: EngineReport) -> some View {
        modifier(ReportAvailability(report: report))
    }
}
