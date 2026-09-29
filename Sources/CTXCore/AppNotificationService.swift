import Foundation
import UserNotifications

public struct ClusterAnomalyNotificationPayload: Sendable {
    public let contextID: String
    public let contextName: String
    public let resourceKind: String
    public let resourceName: String
    public let namespace: String?
    public let ruleId: String
    public let title: String
    public let message: String
    public let isCritical: Bool

    public init(
        contextID: String,
        contextName: String,
        resourceKind: String,
        resourceName: String,
        namespace: String?,
        ruleId: String,
        title: String,
        message: String,
        isCritical: Bool
    ) {
        self.contextID = contextID
        self.contextName = contextName
        self.resourceKind = resourceKind
        self.resourceName = resourceName
        self.namespace = namespace
        self.ruleId = ruleId
        self.title = title
        self.message = message
        self.isCritical = isCritical
    }
}

public final class AppNotificationService: @unchecked Sendable {
    public static let shared = AppNotificationService()

    private let alertLock = NSLock()
    private var lastAlertTimestamps: [String: Date] = [:]
    private static let cooldownInterval: TimeInterval = 600 // 10 minutes debounce per unique anomaly

    public static let categoryClusterAnomaly = "CLUSTER_ANOMALY"
    public static let actionOpenWorkspace = "ACTION_OPEN_WORKSPACE"

    public init() {}

    public func requestAuthorizationIfAvailable() {
        guard Self.canUseNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            if granted {
                self?.registerNotificationCategories()
            }
        }
    }

    public func registerNotificationCategories() {
        guard Self.canUseNotifications else { return }
        let openAction = UNNotificationAction(
            identifier: Self.actionOpenWorkspace,
            title: "Inspect in CTX",
            options: [.foreground]
        )

        let anomalyCategory = UNNotificationCategory(
            identifier: Self.categoryClusterAnomaly,
            actions: [openAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([anomalyCategory])
    }

    /// Sends a debounced native macOS notification for a critical cluster issue or anomaly.
    /// Strictly operates only for actively loaded / connected workspaces.
    public func sendClusterAnomaly(_ anomaly: ClusterAnomalyNotificationPayload) {
        guard Self.canUseNotifications else { return }

        // Check user preferences
        let userDefaults = UserDefaults.standard
        let isEnabled = userDefaults.object(forKey: "enableClusterNotifications") == nil ? true : userDefaults.bool(forKey: "enableClusterNotifications")
        guard isEnabled else { return }

        let criticalOnly = userDefaults.object(forKey: "clusterNotificationsCriticalOnly") == nil ? true : userDefaults.bool(forKey: "clusterNotificationsCriticalOnly")
        if criticalOnly && !anomaly.isCritical {
            return
        }

        // Smart Debounce: Prevent repeated notifications for the same resource failure within cooldown window
        let debounceKey = "\(anomaly.contextID):\(anomaly.resourceKind):\(anomaly.namespace ?? "-"):\(anomaly.resourceName):\(anomaly.ruleId)"
        alertLock.lock()
        let now = Date()
        if let lastTime = lastAlertTimestamps[debounceKey], now.timeIntervalSince(lastTime) < Self.cooldownInterval {
            alertLock.unlock()
            return
        }
        lastAlertTimestamps[debounceKey] = now
        alertLock.unlock()

        let content = UNMutableNotificationContent()
        content.title = "\(anomaly.isCritical ? "🚨 Critical" : "⚠️ Warning"): [\(anomaly.contextName)]"
        let nsPart = anomaly.namespace != nil ? " (\(anomaly.namespace!))" : ""
        content.subtitle = "\(anomaly.resourceKind) \(anomaly.resourceName)\(nsPart)"
        content.body = "\(anomaly.title): \(anomaly.message)"
        content.sound = anomaly.isCritical ? UNNotificationSound.defaultCritical : UNNotificationSound.default
        content.categoryIdentifier = Self.categoryClusterAnomaly
        content.threadIdentifier = "cluster.\(anomaly.contextID)"
        content.userInfo = [
            "type": "cluster_anomaly",
            "context_id": anomaly.contextID,
            "resource_kind": anomaly.resourceKind,
            "resource_name": anomaly.resourceName,
            "namespace": anomaly.namespace ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "cluster.anomaly.\(debounceKey)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Sends an instant test notification so the user can verify their system settings
    public func sendTestNotification(clusterName: String = "production-cluster") {
        guard Self.canUseNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "🔔 CTX Notifications Active"
        content.subtitle = "Connected: [\(clusterName)]"
        content.body = "Native macOS alerts for cluster health, Pod crashes, and diagnostic anomalies are configured."
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = Self.categoryClusterAnomaly
        content.userInfo = [
            "type": "test",
            "context_name": clusterName
        ]

        let request = UNNotificationRequest(
            identifier: "ctx.test.notification.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { _ in }
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
