import CTXCore
import SwiftUI

enum SidebarSheet: Identifiable {
    case addAWSProfile
    case addGCPProfile
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
        List(selection: $store.selectedProfileID) {
            ForEach(store.groupedProfiles) { group in
                ProfileDisclosureGroup(
                    group: group,
                    selectedProfileID: store.selectedProfileID,
                    isExpanded: binding(for: group.id),
                    editFolder: { sheet = .editFolder($0) },
                    deleteFolder: { store.deleteFolder($0) }
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateMenu = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .help("Create Profile or Folder")
            }
        }
        .confirmationDialog("Create", isPresented: $showingCreateMenu) {
            Button("AWS Profile") { sheet = .addAWSProfile }
            Button("GCP Configuration") { sheet = .addGCPProfile }
            Button("Folder") { sheet = .addFolder }
            Button("Cancel", role: .cancel) {}
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
    let selectedProfileID: CloudProfile.ID?
    @Binding var isExpanded: Bool
    let editFolder: (CloudFolder) -> Void
    let deleteFolder: (CloudFolder) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.profiles) { profile in
                SidebarProfileRow(
                    profile: profile,
                    isSelected: selectedProfileID == profile.id
                )
                .tag(profile.id)
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
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .contextMenu {
            Button("Edit Folder") { editFolder(group.folder) }
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
