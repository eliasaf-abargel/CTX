import CTXCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction
    @State private var expandedGroups: Set<String> = []
    @State private var deleteCandidate: CloudProfile? = nil
    @State private var expandedProviders: Set<CloudProvider> = Set(CloudProvider.allCases)
    @State private var sidebarSearchQuery = ""

    private var providerGroups: [ProviderGroup] {
        ProfileGrouping.providerGroups(store.groupedProfiles, query: sidebarSearchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom Search Bar (No Blue Focus Ring!)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("Search...", text: $sidebarSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption2)

                if !sidebarSearchQuery.isEmpty {
                    Button {
                        sidebarSearchQuery = ""
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
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(selection: $store.selectedSelection) {
                ForEach(providerGroups) { pGroup in
                    DisclosureGroup(isExpanded: providerBinding(for: pGroup.provider)) {
                        ForEach(pGroup.folderGroups) { group in
                            ProfileDisclosureGroup(
                                group: group,
                                selectedSelection: $store.selectedSelection,
                                isExpanded: binding(for: group.id),
                                deleteCandidate: $deleteCandidate,
                                store: store,
                                editFolder: {
                                    store.presentFolderEditor(.edit($0), from: .mainWindow)
                                },
                                deleteFolder: {
                                    store.requestFolderDeletion($0, from: .mainWindow)
                                }
                            )
                            .tag(SidebarSelection.folder(group.folder.id))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            ProviderIcon(provider: pGroup.provider, size: 13, fallbackTint: .primary)
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
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            
            Divider()
                .padding(.horizontal, 12)
            
            // Settings & Profile Footer
            HStack(spacing: 8) {
                Text(store.localIdentityInitials)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundColor(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                    }
                
                // The macOS user, and only that. Which cloud happens to be connected
                // belongs to the profile that is connected, not to the person - and it
                // is already shown there, on the row and in the detail pane.
                Text(store.localIdentityLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .lineLimit(1)
                
                Spacer()
                
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        openNewProfile()
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }

                    Button {
                        store.presentFolderEditor(.add, from: .mainWindow)
                    } label: {
                        Label("New Folder", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .help("Create Profile or Folder")
            }
        }
        .deleteProfileAlert(store: store, candidate: $deleteCandidate)
        .onChange(of: store.selectedSelection) { _, newValue in
            if case .profile(let profileID) = newValue,
               let profile = store.profiles.first(where: { $0.id == profileID }) {
                let folder = store.folder(for: profile)
                expandedProviders.insert(profile.provider)
                expandedGroups.insert(folder.id)
            }
        }
    }


    private func providerBinding(for provider: CloudProvider) -> Binding<Bool> {
        ProfileGrouping.expansionBinding(for: provider, in: $expandedProviders, forcedOpenWhile: sidebarSearchQuery)
    }

    private func binding(for id: String) -> Binding<Bool> {
        ProfileGrouping.expansionBinding(for: id, in: $expandedGroups, forcedOpenWhile: sidebarSearchQuery)
    }

    private func openNewProfile() {
        let targetFolder: CloudFolder? = if case .folder(let folderID) = store.selectedSelection {
            store.allFolders.first { $0.id == folderID }
        } else {
            nil
        }
        store.presentProfileEditor(.selectProvider(targetFolder: targetFolder), from: .mainWindow)
    }

}

struct ProfileDisclosureGroup: View {
    let group: ProfileGroup
    @Binding var selectedSelection: SidebarSelection?
    @Binding var isExpanded: Bool
    @Binding var deleteCandidate: CloudProfile?
    @ObservedObject var store: ProfileStore
    let editFolder: (CloudFolder) -> Void
    let deleteFolder: (CloudFolder) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.profiles) { profile in
                SidebarProfileRow(
                    profile: profile,
                    isSelected: selectedSelection == .profile(profile.id),
                    onOpenTerminal: { store.openTerminal(for: profile) },
                    connection: store.connectionBinding(for: profile, from: .mainWindow)
                )
                .tag(SidebarSelection.profile(profile.id))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.folder.icon.systemImage)
                    .font(.system(.caption2, weight: .semibold))
                    .frame(width: 16)

                Text(group.folder.name)
                    .lineLimit(1)

                if group.profiles.contains(where: { $0.status == .connected }) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                }

                Spacer()

                Text("\(group.profiles.count)")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedSelection = .folder(group.folder.id)
            }
            .accessibilityAddTraits(.isButton)
            .contextMenu {
                Button {
                    editFolder(group.folder)
                } label: {
                    Label("Rename & change icon...", systemImage: "pencil")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    deleteFolder(group.folder)
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct SidebarProfileRow: View {
    let profile: CloudProfile
    let isSelected: Bool
    var onOpenTerminal: (() -> Void)?
    var connection: Binding<Bool>?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(
                provider: profile.provider,
                size: 14,
                fallbackTint: isSelected ? .white : (profile.status == .connected ? Color.green : profile.status.color)
            )
            .frame(width: 18)

            Text(profile.name)
                .font(.body)
                .lineLimit(1)

            // The switch already says "connected", so a green dot beside it would say it
            // twice. Orange is kept: it means off for a reason, which a switch alone
            // cannot express. Busy is carried by the switch itself.
            if profile.status == .needsLogin {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }

            Spacer(minLength: 8)

            if let onOpenTerminal {
                TerminalButton(
                    profile: profile,
                    isVisible: isHovering,
                    size: 11,
                    action: onOpenTerminal
                )
            }

            if let connection {
                MiniSwitch(isOn: connection, isBusy: profile.status.isBusy)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
