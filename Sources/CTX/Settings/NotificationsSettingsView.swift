import CTXCore
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @ObservedObject var store: ProfileStore

    @AppStorage("enableClusterNotifications") private var enableClusterNotifications = true
    @AppStorage("clusterNotificationsCriticalOnly") private var clusterNotificationsCriticalOnly = true
    @AppStorage("enableCloudSessionNotifications") private var enableCloudSessionNotifications = true
    @AppStorage("enableAWSNotifications") private var enableAWSNotifications = true

    @State private var testSent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS Notifications")
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("Configure Apple Notification Center alerts for active cluster anomalies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                Divider()

                // Cluster Anomalies Section
                VStack(alignment: .leading, spacing: 14) {
                    Text("CLUSTER ANOMALIES & HEALTH")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    Toggle(isOn: $enableClusterNotifications) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Cluster Anomaly Desktop Alerts")
                                .font(.system(.subheadline, weight: .medium))
                            Text("Receive native macOS alerts when containers crash, deployments degrade, or volumes fail.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    if enableClusterNotifications {
                        Toggle(isOn: $clusterNotificationsCriticalOnly) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Only Alert on Critical Incidents")
                                    .font(.system(.subheadline, weight: .medium))
                                Text("Limits notifications to CrashLoopBackOff, Degraded Replicas, and Unbound PVCs (ignores warnings).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 20)
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Cloud & Cluster Sessions Section
                VStack(alignment: .leading, spacing: 14) {
                    Text("CLOUD & CLUSTER SESSIONS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    Toggle(isOn: $enableCloudSessionNotifications) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Universal Session Expiration & Auth Alerts")
                                .font(.system(.subheadline, weight: .medium))
                            Text("Sends instant macOS alerts when AWS SSO sessions, Google Cloud auth, Azure logins, or Kubernetes tokens expire. Clicking an alert navigates directly to re-authenticate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Test Action
                VStack(alignment: .leading, spacing: 10) {
                    Text("NOTIFICATION VERIFICATION")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            AppNotificationService.shared.requestAuthorizationIfAvailable()
                            let cluster = store.activeProfile(for: .kubernetes)?.name ?? (store.activeKubeContext.isEmpty ? "demo-cluster" : store.activeKubeContext)
                            AppNotificationService.shared.sendTestNotification(clusterName: cluster)
                            testSent = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                testSent = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: testSent ? "checkmark.circle.fill" : "paperplane.fill")
                                    .foregroundStyle(testSent ? .green : .white)
                                Text(testSent ? "Notification Sent!" : "Send Test Notification")
                            }
                            .font(.system(.subheadline, weight: .medium))
                            .frame(height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(testSent ? .green : .blue)

                        Text("Dispatches a live test banner to macOS Notification Center.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(20)
        }
    }
}
