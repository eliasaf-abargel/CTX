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
                .frame(minWidth: 760, minHeight: 500)
                .onAppear {
                    appDelegate.openWindow = openWindow
                    appDelegate.store = store
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 620)

        WindowGroup("Cluster Workspace", id: "cluster-workspace", for: String.self) { $contextID in
            ClusterWorkspaceScene(store: store, contextID: contextID ?? "")
                .frame(minWidth: 840, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: store.hasActiveConnectedProfile ? "cloud.fill" : "cloud")
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
                        Task { await store.verify(profile, isManualAttempt: true) }
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

        applyAppearance()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in self?.configureWindow(window) }
        }


        for window in NSApp.windows {
            configureWindow(window)
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Applied app-wide so panels and alerts match the theme picker. Windows and
    /// sheets inherit from `NSApp`, so this is the only place it needs setting.
    @MainActor
    private func applyAppearance() {
        let wanted = AppAppearance.current.nsAppearance
        guard NSApp.appearance?.name != wanted?.name else { return }
        NSApp.appearance = wanted
    }

    @MainActor
    private func configureWindow(_ window: NSWindow) {
        CTXWindowChrome.apply(to: window)
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
