import CTXCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ProfileStore
    @State private var sheet: SidebarSheet?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                sheet: $sheet
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        } detail: {
            DetailPane(store: store, sheet: $sheet)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAWSProfile:
                AddAWSProfileView(store: store)
            case .addGCPProfile:
                AddGCPProfileView(store: store)
            case .editProfile(let profile):
                if profile.provider == .aws {
                    AddAWSProfileView(store: store, mode: .edit(profile))
                } else {
                    AddGCPProfileView(store: store, mode: .edit(profile))
                }
            case .duplicateProfile(let profile):
                if profile.provider == .aws {
                    AddAWSProfileView(store: store, mode: .duplicate(profile))
                } else {
                    AddGCPProfileView(store: store, mode: .duplicate(profile))
                }
            case .addFolder:
                FolderEditorView(store: store)
            case .editFolder(let folder):
                FolderEditorView(store: store, folder: folder)
            }
        }
    }
}

struct DetailPane: View {
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let profile = store.selectedProfile {
                    ProfileDetailView(profile: profile, store: store, sheet: $sheet)
                        .navigationTitle(profile.name)
                } else {
                    ContentUnavailableView("No Profiles Selected", systemImage: "cloud.slash")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("CTX")
                }
            }
            
            // Floating session expiration warning banner
            if store.showExpirationWarning {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text(store.expirationWarningMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 12)
                .zIndex(100)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.showExpirationWarning)
        .toolbar {
            // Principal active profile indicator in the titlebar (uses native alignment)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 12) {
                    if !store.activeAWSProfile.isEmpty {
                        let activeAWS = store.profiles.first(where: { $0.provider == .aws && $0.name == store.activeAWSProfile })
                        let statusColor = activeAWS?.status.color ?? .gray
                        
                        HStack(spacing: 6) {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text("AWS: \(store.activeAWSProfile)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    
                    if !store.activeGCPProfile.isEmpty {
                        let activeGCP = store.profiles.first(where: { $0.provider == .gcp && $0.name == store.activeGCPProfile })
                        let statusColor = activeGCP?.status.color ?? .gray
                        
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text("GCP: \(store.activeGCPProfile)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Text("EA")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Color.accentColor)
                }
                .buttonStyle(.bordered)
                .help("eliasaf.abargel@gmail.com")
            }
        }
    }
}

