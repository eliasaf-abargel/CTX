import CTXCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        TabView(selection: $store.selectedSettingsTab) {
            ProvidersSettingsView(store: store)
                .tabItem { Label("Cloud Config", systemImage: "cloud") }
                .tag(0)

            FoldersSettingsView(store: store)
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag(1)

            AboutSettingsView(store: store)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(2)

            MCPSettingsView()
                .tabItem { Label("MCP Server", systemImage: "cpu") }
                .tag(3)

            NotificationsSettingsView(store: store)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(4)
        }
        .preferredColorScheme((AppAppearance(rawValue: appAppearanceRaw) ?? .dark).colorScheme)
        .frame(width: 620, height: 460)
        // Settings is a standard, opaque macOS window. Vibrancy here blends
        // against a window with no background of its own, which is what made it
        // — and the open panel run over it — see-through.
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
        .profileLifecyclePresentationHost(store: store, surface: .settings)
    }
}
