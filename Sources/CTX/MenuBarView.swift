import CTXCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: ProfileStore
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRaw: String = AppAppearance.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction
    @State private var expandedGroups: Set<String> = []
    @State private var expandedProviders: Set<CloudProvider> = Set(CloudProvider.allCases)
    @State private var searchQuery = ""

    private var providerGroups: [ProviderGroup] {
        ProfileGrouping.providerGroups(store.groupedProfiles, query: searchQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            let activeProfiles = activeMenuProfiles
            if !activeProfiles.isEmpty {
                VStack(spacing: 8) {
                    ForEach(activeProfiles) { profile in
                        ActiveContextPill(
                            profile: profile,
                            expiresAt: store.sessionExpiry(for: profile)
                        )
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if store.showExpirationWarning {
                Button {
                    if let id = store.expirationWarningProfileID,
                       let profile = store.profiles.first(where: { $0.id == id }) {
                        store.selectProfile(profile)
                        store.login(profile, from: .menuBar)
                    } else if let profile = store.selectedProfile {
                        store.login(profile, from: .menuBar)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "timer")
                            .font(.system(.caption2, weight: .bold))
                        Text(store.expirationWarningMessage)
                            .font(.system(.caption2, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(.caption2))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if store.updateAvailable {
                Button {
                    store.installUpdate()
                } label: {
                    HStack(spacing: 8) {
                        if store.isUpdating {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                                .frame(width: 11, height: 11)
                            Text("Installing Update...")
                                .font(.system(.caption2, weight: .semibold))
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(.caption2, weight: .bold))
                            Text("Update Available: \(store.latestVersionString)")
                                .font(.system(.caption2, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.down.to.line.compact")
                                .font(.system(.caption2, weight: .bold))
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.isUpdating)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("Search...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption2)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .ctxGlassCard(cornerRadius: 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(providerGroups) { pGroup in
                        DisclosureGroup(isExpanded: providerBinding(for: pGroup.provider)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(pGroup.folderGroups) { group in
                                    MenuBarFolderSection(
                                        group: group,
                                        isExpanded: binding(for: group.id),
                                        activeProfileName: store.activeProfileName(for: group.folder.provider),
                                        selectBinding: activeBinding(for:),
                                        openTerminal: { store.openTerminal(for: $0) }
                                    )
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 6) {
                                ProviderIcon(provider: pGroup.provider, size: 12, fallbackTint: .primary)
                                Text(pGroup.provider.sectionHeaderTitle)
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(.primary)

                                if pGroup.folderGroups.contains(where: { g in g.profiles.contains { $0.status == .connected } }) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 5, height: 5)
                                }

                                Spacer()

                                let totalCount = pGroup.folderGroups.reduce(0) { $0 + $1.profiles.count }
                                Text("\(totalCount)")
                                    .font(.system(.caption2, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
                .padding(.trailing, 10)
            }
            .frame(maxHeight: 320)

            Divider()

            HStack(spacing: 8) {
                Button("Open CTX") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .buttonStyle(CTXSecondaryButton())

                if let context = activeKubernetesContext {
                    Button("Workspace") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "cluster-workspace", value: context.id)
                    }
                    .buttonStyle(CTXPrimaryButton())
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(CTXSecondaryButton())
            }
        }
        .padding(14)
        .frame(width: 300, height: 500)
        .preferredColorScheme((AppAppearance(rawValue: appAppearanceRaw) ?? .dark).colorScheme)
        .background(
            ZStack {
                if colorScheme == .light {
                    Color(NSColor.controlBackgroundColor)
                } else {
                    Color(red: 0.11, green: 0.13, blue: 0.16)
                }
            }
            .ignoresSafeArea()
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.showExpirationWarning)
        .onAppear {
            expandedGroups = []
            store.checkForUpdates()
        }
        .onChange(of: store.presentation?.id) { _, _ in
            guard let presentation = store.presentation,
                  presentation.requestedOrigin == .menuBar,
                  presentation.origin == .mainWindow else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                CTXAppLogoView(size: 28)

                Text("CTX")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Settings")
                .accessibilityLabel("Open Settings")

                Text(store.activeIdentityInitials)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                    }
                    .help("Signed in as \(store.activeIdentityLabel)")
            }
        }
    }

    private var activeMenuProfiles: [CloudProfile] {
        store.connectedProfiles
    }

    private var activeKubernetesContext: KubernetesContextProfile? {
        guard !store.activeKubeContext.isEmpty else { return nil }
        return store.kubernetesContexts.first { $0.contextName == store.activeKubeContext }
    }

    private func providerBinding(for provider: CloudProvider) -> Binding<Bool> {
        ProfileGrouping.expansionBinding(for: provider, in: $expandedProviders, forcedOpenWhile: searchQuery)
    }

    private func binding(for id: String) -> Binding<Bool> {
        ProfileGrouping.expansionBinding(for: id, in: $expandedGroups, forcedOpenWhile: searchQuery)
    }


    private func activeBinding(for profile: CloudProfile) -> Binding<Bool> {
        store.connectionBinding(for: profile, from: .menuBar)
    }


}

private struct ActiveContextPill: View {
    let profile: CloudProfile
    let expiresAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(profile.status.color)
                .frame(width: 5, height: 5)
                .shadow(color: profile.status.color.opacity(0.4), radius: 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\(profile.provider.compactName) \(profile.name)")
                        .font(.system(.caption2, weight: .bold))
                        .lineLimit(1)
                    
                    if profile.status != .connected {
                        Text("(\(profile.status.rawValue))")
                            .font(.system(.caption2, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if !profile.contextSubtitle.isEmpty {
                    Text(profile.contextSubtitle)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let expiresAt, expiresAt > Date() {
                Spacer(minLength: 6)
                SessionCountdownView(expiresAt: expiresAt, tintColor: profile.provider.tint, fontSize: 10)
            }
        }
        .foregroundStyle(profile.provider.tint)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ctxGlassCard(cornerRadius: 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(profile.provider.tint.opacity(0.08))
        )
    }
}

private struct MenuBarFolderSection: View {
    let group: ProfileGroup
    @Binding var isExpanded: Bool
    let activeProfileName: String
    let selectBinding: (CloudProfile) -> Binding<Bool>
    let openTerminal: (CloudProfile) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.profiles) { profile in
                    MenuBarProfileRow(
                        profile: profile,
                        isActive: activeProfileName == profile.name,
                        isOn: selectBinding(profile),
                        onOpenTerminal: { openTerminal(profile) }
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.folder.icon.systemImage)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(group.folder.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if group.profiles.contains(where: { $0.status == .connected }) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 4, height: 4)
                }

                Spacer()

                Text("\(group.profiles.count)")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .contentShape(Rectangle())
        }
    }
}

private struct MenuBarProfileRow: View {
    let profile: CloudProfile
    let isActive: Bool
    @Binding var isOn: Bool
    var onOpenTerminal: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(
                provider: profile.provider,
                size: 12,
                fallbackTint: isActive ? profile.provider.tint : (profile.status == .connected ? Color.green : profile.status.color)
            )
            .frame(width: 14)

            Text(profile.name)
                .font(.system(.caption2, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)

            // The switch already says "connected", so a green dot beside it would say it
            // twice. Orange is kept: it means off for a reason, which a switch alone
            // cannot express. Busy is carried by the switch itself.
            if profile.status == .needsLogin {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }

            Spacer(minLength: 8)

            if let onOpenTerminal {
                TerminalButton(
                    profile: profile,
                    isVisible: isHovering,
                    size: 10.5,
                    action: onOpenTerminal
                )
            }

            MiniSwitch(isOn: $isOn, isBusy: profile.status.isBusy)
        }
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(isActive ? "active" : profile.status.rawValue)")
    }
}

