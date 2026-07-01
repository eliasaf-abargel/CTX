import CTXCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction
    @State private var expandedGroups: Set<String> = []
    @State private var searchQuery = ""

    private var filteredGroupedProfiles: [ProfileGroup] {
        if searchQuery.isEmpty {
            return store.groupedProfiles
        }
        return store.groupedProfiles.compactMap { group in
            let matchesFolder = group.folder.name.localizedCaseInsensitiveContains(searchQuery)
                || group.folder.provider.rawValue.localizedCaseInsensitiveContains(searchQuery)

            let matchingProfiles = group.profiles.filter { profile in
                profile.name.localizedCaseInsensitiveContains(searchQuery)
                    || profile.provider.rawValue.localizedCaseInsensitiveContains(searchQuery)
            }

            if matchesFolder {
                return group
            } else if !matchingProfiles.isEmpty {
                return ProfileGroup(folder: group.folder, profiles: matchingProfiles)
            } else {
                return nil
            }
        }
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
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator.opacity(0.1), lineWidth: 0.5)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredGroupedProfiles) { group in
                        if !group.profiles.isEmpty {
                            MenuBarFolderSection(
                                group: group,
                                isExpanded: binding(for: group.id),
                                activeProfileName: activeName(for: group.folder.provider),
                                selectBinding: activeBinding(for:)
                            )
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
                .buttonStyle(.bordered)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300, height: 500)
        .background(.regularMaterial)
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
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

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
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.gradient, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.25), lineWidth: 0.5)
                    }
                    .help("Signed in as \(store.activeIdentityLabel)")
            }
        }
    }

    private var activeMenuProfiles: [CloudProfile] {
        [
            (.aws, store.activeAWSProfile),
            (.gcp, store.activeGCPProfile),
            (.azure, store.activeAzureProfile),
            (.kubernetes, store.activeKubeContext)
        ].compactMap { provider, name in
            guard !name.isEmpty else { return nil }
            return store.profiles.first { $0.provider == provider && $0.name == name }
        }
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

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) || !searchQuery.isEmpty },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(id)
                } else {
                    expandedGroups.remove(id)
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
                .fill(Color.green)
                .frame(width: 5, height: 5)
                .shadow(color: .green.opacity(0.4), radius: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(profile.provider.compactName) \(profile.name)")
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)

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
        .background(profile.provider.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(profile.provider.tint.opacity(0.24), lineWidth: 0.5)
        }
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
                Label("\(group.folder.provider.rawValue) · \(group.folder.name)", systemImage: group.folder.icon.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
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
                fallbackTint: isActive ? profile.provider.tint : (profile.status == .connected ? Color.green : Color.secondary)
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
