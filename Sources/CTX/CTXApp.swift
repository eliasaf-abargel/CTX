import CTXCore
import SwiftUI
import UserNotifications

@main
struct CTXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ProfileStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("CTX", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 680, minHeight: 480)
                .onAppear {
                    appDelegate.openWindow = openWindow
                    appDelegate.store = store
                }
        }
        .defaultSize(width: 980, height: 620)

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: (store.activeAWSProfile.isEmpty && store.activeGCPProfile.isEmpty && store.activeAzureProfile.isEmpty && store.activeKubeContext.isEmpty) ? "cloud" : "cloud.fill")
                
                if !store.activeAWSProfile.isEmpty,
                   let expiresAt = store.activeAWSExpiresAt, expiresAt > Date() {
                    MenuBarTimerView(expiresAt: expiresAt)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }

        .commands {
            CommandMenu("Cloud") {
                Button("Refresh Profiles") {
                    store.refresh()
                }
                .keyboardShortcut("r")

                if let profile = store.selectedProfile {
                    Button("Connect Selected Profile") {
                        store.login(profile)
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])

                    Button("Verify Selected Profile") {
                        Task { await store.verify(profile) }
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var openWindow: OpenWindowAction?
    var store: ProfileStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["type"] as? String == "update" {
            DispatchQueue.main.async {
                if let store = self.store {
                    store.selectedSettingsTab = 2
                }
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        completionHandler()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindow?(id: "main")
        } else {
            for window in NSApp.windows {
                if window.title == "CTX" || window.identifier?.rawValue == "main" || window.className.contains("Settings") {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

struct MenuBarTimerView: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            let seconds = Int(remaining) % 60
            
            if hours > 0 {
                Text(String(format: "%d:%02d:%02d", hours, minutes, seconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            } else {
                Text(String(format: "%02d:%02d", minutes, seconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}
