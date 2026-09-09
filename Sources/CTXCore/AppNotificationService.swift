import Foundation
import UserNotifications

public final class AppNotificationService: Sendable {
    public init() {}

    public func requestAuthorizationIfAvailable() {
        guard Self.canUseNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func sendAWSExpiration(profileName: String, expired: Bool) {
        guard Self.canUseNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = expired ? "Session Expired" : "Session Expiring"
        content.body = expired
            ? "AWS profile \(profileName) session has expired."
            : "AWS profile \(profileName) session expires in 2m."
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(
            identifier: "aws.session.expiration.\(profileName)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Announces a repair of `~/.aws/config`. Rewriting a person's configuration
    /// silently is the kind of surprise that reads as the app breaking their setup -
    /// especially since the merge invalidates cached tokens and every profile asks
    /// for a sign-in once afterwards.
    public func sendSSOSessionsMerged(mergedCount: Int, keptSessions: [String]) {
        guard Self.canUseNotifications, mergedCount > 0 else { return }

        let names = keptSessions.sorted().joined(separator: ", ")
        let content = UNMutableNotificationContent()
        content.title = "AWS Config Repaired"
        content.body = """
        Merged \(mergedCount) duplicate SSO session\(mergedCount == 1 ? "" : "s") into \(names), \
        so profiles sharing a portal now share one sign-in. Sign in once to reconnect. \
        A backup of the previous config was saved beside it.
        """
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(
            identifier: "aws.config.sessions.merged",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    public func sendUpdateAvailable(version: String) {
        guard Self.canUseNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "A new version \(version) of CTX is available. Click to open Settings and update."
        content.sound = UNNotificationSound.default
        content.userInfo = ["type": "update"]

        let request = UNNotificationRequest(
            identifier: "ctx.update.available",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private static var canUseNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
