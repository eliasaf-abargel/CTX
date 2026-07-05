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
