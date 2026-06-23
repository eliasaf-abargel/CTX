import CTXCore
import SwiftUI

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
                }
        }
        .defaultSize(width: 980, height: 620)

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: (store.activeAWSProfile.isEmpty && store.activeGCPProfile.isEmpty) ? "cloud" : "cloud.fill")
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openWindow: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
