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
                } else if let folder = store.selectedFolder {
                    FolderDetailView(folder: folder, store: store, sheet: $sheet)
                        .navigationTitle(folder.name)
                } else {
                    WelcomeView()
                        .navigationTitle("CTX")
                }
            }
            
            // Floating notification stack
            VStack(spacing: 8) {
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
                }
                
                if store.updateAvailable {
                    Button {
                        store.selectedSettingsTab = 2
                        openSettings()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Update Available: \(store.latestVersionString). Click to open settings.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
            .zIndex(100)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.showExpirationWarning)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.updateAvailable)
        .toolbar {
            // Principal active profile indicator in the titlebar (uses native alignment)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 12) {
                    if !store.activeAWSProfile.isEmpty,
                       let activeAWS = store.profiles.first(where: { $0.provider == .aws && $0.name == store.activeAWSProfile }) {
                        let statusColor = activeAWS.status.color
                        
                        HStack(spacing: 6) {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(statusColor)
                            
                            Text("AWS: \(store.activeAWSProfile)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.85))
                            
                            Divider()
                                .frame(height: 10)
                                .background(Color.secondary.opacity(0.3))
                            
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.logout(activeAWS)
                                }
                                .help("Disconnect active AWS profile")
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.separator.opacity(0.15), lineWidth: 0.5)
                        }
                    }
                    
                    if !store.activeGCPProfile.isEmpty,
                       let activeGCP = store.profiles.first(where: { $0.provider == .gcp && $0.name == store.activeGCPProfile }) {
                        let statusColor = activeGCP.status.color
                        
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 9))
                                .foregroundStyle(statusColor)
                            
                            Text("GCP: \(store.activeGCPProfile)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.85))
                            
                            Divider()
                                .frame(height: 10)
                                .background(Color.secondary.opacity(0.3))
                            
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.logout(activeGCP)
                                }
                                .help("Disconnect active GCP configuration")
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.separator.opacity(0.15), lineWidth: 0.5)
                        }
                    }
                }
                .buttonStyle(.plain)
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
                .help("eliasafabargel@gmail.com")
            }
        }
    }
}

struct FolderDetailView: View {
    let folder: CloudFolder
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?

    var body: some View {
        ScrollView {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 28) {
                    // Header Hero
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: folder.icon.systemImage)
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.separator.opacity(0.3), lineWidth: 1)
                            }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("\(folder.provider.rawValue) · \(folder.name)")
                                    .font(.title2.weight(.semibold))
                                
                                Button {
                                    sheet = .editFolder(folder)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Rename Folder")
                            }
                            Text("Environment folder containing profiles")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Button {
                            if folder.provider == .aws {
                                sheet = .addAWSProfile
                            } else {
                                sheet = .addGCPProfile
                            }
                        } label: {
                            Label("Add Profile", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    
                    Divider()
                    
                    let profiles = store.profiles.filter {
                        $0.provider == folder.provider && store.folder(for: $0).id == folder.id
                    }
                    
                    if profiles.isEmpty {
                        ContentUnavailableView("No Profiles in Folder", systemImage: "cloud.slash", description: Text("Click the + button in the sidebar to add a profile to this folder."))
                            .padding(.vertical, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Profiles (\(profiles.count))")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            VStack(spacing: 12) {
                                ForEach(profiles) { profile in
                                    FolderProfileRow(profile: profile, store: store, sheet: $sheet)
                                }
                            }
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: 640)
                Spacer()
            }
        }
    }
}

struct FolderProfileRow: View {
    let profile: CloudProfile
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(profile.status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.body.weight(.semibold))
                    
                    if store.isActive(profile) {
                        Text("Active")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor, in: Capsule())
                    }
                }

                if profile.provider == .aws {
                    Text("Role: \(profile.roleName)  ·  Account: \(profile.accountID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Account: \(profile.roleName)  ·  Project: \(profile.accountID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if profile.status == .connected {
                    Button("Disconnect") {
                        store.logout(profile)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Connect") {
                        store.login(profile)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if !store.isActive(profile) {
                    Button("Activate") {
                        store.setActive(profile)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    sheet = .editProfile(profile)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit Profile")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.2), lineWidth: 1)
        }
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
            } else {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 8) {
                Text("Welcome to CTX")
                    .font(.title3.weight(.bold))
                Text("Select a profile or environment folder in the sidebar to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

