import CTXCore
import SwiftUI

enum SidebarSheet: Identifiable {
    case addAWSProfile
    case addGCPProfile
    case addAzureProfile
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

    var body: some View {
        List(selection: $store.selectedSelection) {
            ForEach(store.groupedProfiles) { group in
                ProfileDisclosureGroup(
                    group: group,
                    selectedSelection: $store.selectedSelection,
                    isExpanded: binding(for: group.id),
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
                            case .kubernetes: break
                            }
                        }
                        Divider()
                    }
                    Button("AWS Profile...") { sheet = .addAWSProfile }
                    Button("GCP Configuration...") { sheet = .addGCPProfile }
                    Button("Azure Subscription...") { sheet = .addAzureProfile }
                    Button("New Folder...") { sheet = .addFolder }
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .help("Create Profile or Folder")
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
        }
        .contextMenu {
            Button("Rename Folder") { editFolder(group.folder) }
            Button("Delete Folder", role: .destructive) { deleteFolder(group.folder) }
        }
    }
}

struct SidebarProfileRow: View {
    let profile: CloudProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "cloud.fill" : "cloud")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : (profile.status == .connected ? Color.green : Color.accentColor))
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
