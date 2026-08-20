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
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .bold))
                    Text(store.expirationWarningMessage)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Update Available: \(store.latestVersionString)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.down.to.line.compact")
                                .font(.system(size: 10, weight: .bold))
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                TextField("Search...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                                        activeProfileName: activeName(for: group.folder.provider),
                                        selectBinding: activeBinding(for:)
                                    )
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 6) {
                                ProviderIcon(provider: pGroup.provider, size: 12, fallbackTint: .primary)
                                Text(pGroup.provider.sectionHeaderTitle)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.primary)

                                if pGroup.folderGroups.contains(where: { g in g.profiles.contains { $0.status == .connected } }) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 5, height: 5)
                                }

                                Spacer()

                                let totalCount = pGroup.folderGroups.reduce(0) { $0 + $1.profiles.count }
                                Text("\(totalCount)")
                                    .font(.system(size: 9.5, weight: .semibold))
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
            store.verifyAllProfiles()
            store.checkForUpdates()
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
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Settings")
                .accessibilityLabel("Open Settings")

                Text(store.activeIdentityInitials)
                    .font(.system(size: 11, weight: .bold))
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
        CloudProvider.allCases.compactMap { provider in
            store.activeProfile(for: provider)
        }
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

    private func activeName(for provider: CloudProvider) -> String {
        switch provider {
        case .aws: store.activeAWSProfile
        case .gcp: store.activeGCPProfile
        case .azure: store.activeAzureProfile
        case .kubernetes: store.activeKubeContext
        }
    }

    private func activeBinding(for profile: CloudProfile) -> Binding<Bool> {
        Binding(
            get: { store.isActive(profile) },
            set: { isOn in
                if isOn {
                    store.login(profile)
                } else if store.isActive(profile) {
                    store.logout(profile)
                }
            }
        )
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
                        .font(.system(size: 11.5, weight: .bold))
                        .lineLimit(1)
                    
                    if profile.status != .connected {
                        Text("(\(profile.status.rawValue))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if !profile.contextSubtitle.isEmpty {
                    Text(profile.contextSubtitle)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
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

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.profiles) { profile in
                    MenuBarProfileRow(
                        profile: profile,
                        isActive: activeProfileName == profile.name,
                        isOn: selectBinding(profile)
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.folder.icon.systemImage)
                    .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 9, weight: .semibold))
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

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(
                provider: profile.provider,
                size: 12,
                fallbackTint: isActive ? profile.provider.tint : (profile.status == .connected ? Color.green : profile.status.color)
            )
            .frame(width: 14)

            Text(profile.name)
                .font(.system(size: 11.5, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)

            if profile.status == .connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 4, height: 4)
            } else if profile.status.isBusy {
                Circle()
                    .fill(profile.status.color)
                    .frame(width: 4, height: 4)
            } else if profile.status == .needsLogin {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }

            Spacer(minLength: 8)

            MiniSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(isActive ? "active" : profile.status.rawValue)")
    }
}

private struct MiniSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor.opacity(0.88) : Color.secondary.opacity(0.18))
                    .background(.thinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(isOn ? 0.24 : 0.12), lineWidth: 0.5)
                    }
                    .frame(width: 28, height: 16)
                    .shadow(color: (isOn ? Color.accentColor : Color.black).opacity(0.22), radius: 3, y: 1)

                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .padding(2)
                    .shadow(color: .black.opacity(0.24), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Disconnect" : "Connect")
    }
}
