import VBXCore
import Foundation
import UserNotifications

/// Delivers critical alerts as system notifications while the workspace is
/// being watched.
///
/// Deliberately best-effort. Notification authorisation can be refused, and
/// `UNUserNotificationCenter.current()` traps outright in a process with no
/// bundle identifier — which is exactly how the test suite and the CLI run.
/// A health alert is not worth crashing over, so every path here degrades to
/// doing nothing.
public actor AlertNotifier {
    private var authorised: Bool?

    public init() {}

    /// True when the process can use the notification centre at all.
    ///
    /// `UNUserNotificationCenter.current()` requires a bundle identifier;
    /// without one it raises rather than returning nil, so the check has to
    /// happen before the call, not around it.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Asks for permission once, remembering the answer.
    private func ensureAuthorised() async -> Bool {
        if let authorised { return authorised }
        guard isAvailable else {
            authorised = false
            return false
        }

        let centre = UNUserNotificationCenter.current()
        let granted =
            (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        authorised = granted
        return granted
    }

    /// A notification's body: the message, then bv's suggested action on its
    /// own line when there is one — the remedy is what makes a notification
    /// worth acting on from where it lands.
    public nonisolated static func body(for alert: HealthAlert) -> String {
        guard let action = alert.suggestedAction else { return alert.message }
        return "\(alert.message)\n\(action)"
    }

    /// Posts one notification per alert, worst first.
    public func deliver(_ alerts: [HealthAlert]) async {
        guard !alerts.isEmpty, await ensureAuthorised() else { return }

        let centre = UNUserNotificationCenter.current()
        for alert in alerts.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = alert.typeDisplayName
            content.body = Self.body(for: alert)
            if !alert.issueID.isEmpty {
                content.subtitle = alert.issueID
                // The bead id rides along so a tap can select it.
                content.userInfo = ["bead": alert.issueID]
            }
            content.sound = .default

            // The alert's own id is the request id, so the same standing
            // problem replaces its previous notification rather than stacking
            // a new one beside it.
            let request = UNNotificationRequest(
                identifier: alert.id, content: content, trigger: nil)
            try? await centre.add(request)
        }
    }
}
