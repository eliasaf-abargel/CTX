import CTXCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row 1: App Title & User Avatar
            HStack {
                Text("CTX")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    openSettings()
                } label: {
                    Text(store.activeIdentityInitials)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Signed in as \(store.activeIdentityLabel)")
            }

            // Header Row 2: Active Profile Capsules (Flowing/Scrollable)
            let hasActive = !store.activeAWSProfile.isEmpty || !store.activeGCPProfile.isEmpty || !store.activeAzureProfile.isEmpty || !store.activeKubeContext.isEmpty
            
            if hasActive {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // AWS Active Capsule
                        if !store.activeAWSProfile.isEmpty,
                           let activeAWS = store.profiles.first(where: { $0.provider == .aws && $0.name == store.activeAWSProfile }) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                
                                Text("AWS \(store.activeAWSProfile)")
                                    .font(.system(size: 9, weight: .bold))
                                
                                if activeAWS.status == .connected, let expiresAt = store.activeAWSExpiresAt, expiresAt > Date() {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        let remaining = max(0, expiresAt.timeIntervalSince(context.date))
                                        let hours = Int(remaining) / 3600
                                        let minutes = (Int(remaining) % 3600) / 60
                                        let seconds = Int(remaining) % 60
                                        if hours > 0 {
                                            Text(String(format: "%d:%02d:%02d", hours, minutes, seconds))
                                        } else {
                                            Text(String(format: "%02d:%02d", minutes, seconds))
                                        }
                                    }
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                }
                            }
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
                            }
                        }

                        // GCP Active Capsule
                        if !store.activeGCPProfile.isEmpty {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                
                                Text("GCP \(store.activeGCPProfile)")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.blue.opacity(0.2), lineWidth: 0.5)
                            }
                        }

                        // Azure Active Capsule
                        if !store.activeAzureProfile.isEmpty {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                
                                Text("Azure \(store.activeAzureProfile)")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.cyan.opacity(0.2), lineWidth: 0.5)
                            }
                        }

                        // K8s Active Capsule
                        if !store.activeKubeContext.isEmpty {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                
                                Text("K8s \(store.activeKubeContext)")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Color.indigo)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.indigo.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.indigo.opacity(0.2), lineWidth: 0.5)
                            }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Expiration warning banner inside the popover
            if store.showExpirationWarning {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                    Text(store.expirationWarningMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Update available banner inside the popover
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
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Update Available: \(store.latestVersionString)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "arrow.down.to.line.compact")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.isUpdating)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // Profiles list
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.groupedProfiles) { group in
                        if !group.profiles.isEmpty {
                            MenuBarFolderSection(
                                group: group,
                                isExpanded: binding(for: group.id),
                                activeProfileName: group.folder.provider == .aws ? store.activeAWSProfile : store.activeGCPProfile,
                                selectBinding: activeBinding(for:)
                            )
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(maxHeight: 320)

            Divider()

            // Footer
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
        .padding(12)
        .frame(width: 270, height: 350)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.showExpirationWarning)
        .onAppear {
            store.verifyAllProfiles()
            store.checkForUpdates()
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
            get: { expandedGroups.contains(id) },
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
            Image(systemName: isActive ? "cloud.fill" : "cloud")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.accentColor : (profile.status == .connected ? Color.green : Color.secondary))
                .frame(width: 18)

            Text(profile.name)
                .font(.body)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)

            if profile.status == .connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            } else if profile.status == .needsLogin {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }

            Spacer(minLength: 8)

            MiniSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .contentShape(Rectangle())
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
                    .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 28, height: 16)
                
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
