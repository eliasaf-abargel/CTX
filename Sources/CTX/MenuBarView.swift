import CTXCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Text("CTX")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !store.activeAWSProfile.isEmpty,
                   let activeAWS = store.profiles.first(where: { $0.provider == .aws && $0.name == store.activeAWSProfile }) {
                    let statusColor = activeAWS.status.color
                    HStack(spacing: 5) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor)
                        Text("AWS:\(store.activeAWSProfile)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        
                        Button {
                            store.logout(activeAWS)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                if !store.activeGCPProfile.isEmpty,
                   let activeGCP = store.profiles.first(where: { $0.provider == .gcp && $0.name == store.activeGCPProfile }) {
                    let statusColor = activeGCP.status.color
                    HStack(spacing: 5) {
                        Image(systemName: "globe")
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor)
                        Text("GCP:\(store.activeGCPProfile)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        
                        Button {
                            store.logout(activeGCP)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                Spacer()

                Button {
                    openSettings()
                } label: {
                    Text("EA")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .foregroundColor(Color.accentColor)
                        .overlay {
                            Circle()
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("eliasafabargel@gmail.com")
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
                    if let url = URL(string: "https://github.com/eliasaf-abargel/CTX/releases/latest") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Update Available: \(store.latestVersionString)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
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
