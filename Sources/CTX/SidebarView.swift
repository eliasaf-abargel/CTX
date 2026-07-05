import CTXCore
import SwiftUI

enum SidebarSheet: Identifiable {
    case selectProvider
    case addAWSProfile
    case addGCPProfile
    case addAzureProfile
    case addKubeContext
    case editProfile(CloudProfile)
    case duplicateProfile(CloudProfile)
    case addFolder
    case editFolder(CloudFolder)

    var id: String {
        switch self {
        case .selectProvider:
            "selectProvider"
        case .addAWSProfile:
            "addAWSProfile"
        case .addGCPProfile:
            "addGCPProfile"
        case .addAzureProfile:
            "addAzureProfile"
        case .addKubeContext:
            "addKubeContext"
        case .editProfile(let profile):
            "editProfile:\(profile.id)"
        case .duplicateProfile(let profile):
            "duplicateProfile:\(profile.id)"
        case .addFolder:
            "addFolder"
        case .editFolder(let folder):
            "editFolder:\(folder.id)"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction
    @State private var expandedGroups: Set<String> = []
    @State private var deleteCandidate: CloudProfile? = nil
    @State private var sidebarSearchQuery = ""

    private var filteredGroupedProfiles: [ProfileGroup] {
        if sidebarSearchQuery.isEmpty {
            return store.groupedProfiles
        }
        return store.groupedProfiles.compactMap { group in
            let matchesFolder = group.folder.name.localizedCaseInsensitiveContains(sidebarSearchQuery)
                || group.folder.provider.rawValue.localizedCaseInsensitiveContains(sidebarSearchQuery)

            let matchingProfiles = group.profiles.filter { profile in
                profile.name.localizedCaseInsensitiveContains(sidebarSearchQuery)
                    || profile.provider.rawValue.localizedCaseInsensitiveContains(sidebarSearchQuery)
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
        VStack(spacing: 0) {
            // Custom Search Bar (No Blue Focus Ring!)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                TextField("Search...", text: $sidebarSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !sidebarSearchQuery.isEmpty {
                    Button {
                        sidebarSearchQuery = ""
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
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(selection: $store.selectedSelection) {
                ForEach(filteredGroupedProfiles) { group in
                    ProfileDisclosureGroup(
                        group: group,
                        selectedSelection: $store.selectedSelection,
                        isExpanded: binding(for: group.id),
                        sheet: $sheet,
                        deleteCandidate: $deleteCandidate,
                        store: store,
                        editFolder: { sheet = .editFolder($0) },
                        deleteFolder: { store.deleteFolder($0) }
                    )
                    .tag(SidebarSelection.folder(group.folder.id))
                }
            }
            .listStyle(.sidebar)
            
            Divider()
                .padding(.horizontal, 12)
            
            // Settings & Profile Footer
            HStack(spacing: 8) {
                Text(store.activeIdentityInitials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                    }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.activeIdentityLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("Identity Connected")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
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
                        sheet = .addFolder
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
        .alert(
            "Delete \(deleteCandidate?.name ?? "profile")?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let profile = deleteCandidate {
                    do {
                        switch profile.provider {
                        case .aws:
                            try store.deleteAWSProfile(profile)
                        case .gcp:
                            try store.deleteGCPProfile(profile)
                        case .azure:
                            try store.deleteAzureProfile(profile)
                        case .kubernetes:
                            Task {
                                do {
                                    try await store.deleteKubeContext(profile)
                                } catch {
                                    store.report(error.localizedDescription)
                                }
                            }
                        }
                    } catch {
                        store.report(error.localizedDescription)
                    }
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let profile = deleteCandidate {
                switch profile.provider {
                case .aws:
                    Text("CTX will remove this AWS profile and its matching SSO session from ~/.aws/config after creating a backup.")
                case .gcp:
                    Text("CTX will permanently delete the gcloud configuration file config_\(profile.name) from ~/.config/gcloud/configurations/.")
                case .azure:
                    Text("CTX will permanently delete the Azure profile JSON file config_\(profile.name).json from ~/.config/ctx/azure/.")
                case .kubernetes:
                    Text("CTX will delete the context \(profile.name) from your ~/.kube/config configuration file.")
                }
            }
        }
    }

    private func openNewProfile() {
        sheet = .selectProvider
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) || !sidebarSearchQuery.isEmpty },
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

struct ProfileDisclosureGroup: View {
    let group: ProfileGroup
    @Binding var selectedSelection: SidebarSelection?
    @Binding var isExpanded: Bool
    @Binding var sheet: SidebarSheet?
    @Binding var deleteCandidate: CloudProfile?
    @ObservedObject var store: ProfileStore
    let editFolder: (CloudFolder) -> Void
    let deleteFolder: (CloudFolder) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.profiles) { profile in
                SidebarProfileRow(
                    profile: profile,
                    isSelected: selectedSelection == .profile(profile.id)
                )
                .tag(SidebarSelection.profile(profile.id))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.folder.icon.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)

                Text("\(group.folder.provider.rawValue) · \(group.folder.name)")
                    .lineLimit(1)

                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedSelection = .folder(group.folder.id)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
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

            if profile.status == .connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            } else if profile.status.isBusy {
                Circle()
                    .fill(profile.status.color)
                    .frame(width: 6, height: 6)
            } else if profile.status == .needsLogin {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }

            Spacer(minLength: 8)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}
