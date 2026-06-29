import CTXCore
import SwiftUI

enum SidebarSheet: Identifiable {
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
    @State private var expandedGroups: Set<String> = []
    @State private var showingCreateMenu = false
    @State private var deleteCandidate: CloudProfile? = nil

    var body: some View {
        List(selection: $store.selectedSelection) {
            ForEach(store.groupedProfiles) { group in
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
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let folder = store.selectedFolder {
                        Button("Add Profile to \(folder.name)...") {
                            switch folder.provider {
                            case .aws: sheet = .addAWSProfile
                            case .gcp: sheet = .addGCPProfile
                            case .azure: sheet = .addAzureProfile
                            case .kubernetes: sheet = .addKubeContext
                            }
                        }
                        Divider()
                    }
                    Button("AWS Profile...") { sheet = .addAWSProfile }
                    Button("GCP Configuration...") { sheet = .addGCPProfile }
                    Button("Azure Subscription...") { sheet = .addAzureProfile }
                    Button("Kubernetes Context...") { sheet = .addKubeContext }
                    Button("New Folder...") { sheet = .addFolder }
                } label: {
                    Label("Create", systemImage: "plus")
                }
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
                .contextMenu {
                    Button(store.isActive(profile) ? "Active" : "Set Active") {
                        store.setActive(profile)
                    }
                    .disabled(store.isActive(profile))
                    
                    if profile.status == .connected {
                        Button("Disconnect") {
                            store.logout(profile)
                        }
                    } else {
                        Button("Connect") {
                            store.login(profile)
                        }
                    }
                    
                    Button("Verify Status") {
                        Task { await store.verify(profile) }
                    }
                    
                    Divider()
                    
                    Button("Edit \(profile.typeDescription)...") {
                        sheet = .editProfile(profile)
                    }
                    
                    if profile.provider != .kubernetes {
                        Button("Duplicate...") {
                            sheet = .duplicateProfile(profile)
                        }
                    }
                    
                    Menu("Move profile to...") {
                        ForEach(store.allFolders) { folder in
                            if folder.provider == profile.provider {
                                Button(folder.name) {
                                    store.move(profile, to: folder)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button("Delete \(profile.typeDescription)...", role: .destructive) {
                        deleteCandidate = profile
                    }
                }
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
                fallbackTint: isSelected ? .white : (profile.status == .connected ? Color.green : Color.accentColor)
            )
            .frame(width: 18)

            Text(profile.name)
                .font(.body)
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
        }
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}
