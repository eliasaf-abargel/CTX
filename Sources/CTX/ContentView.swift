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
            case .addAzureProfile:
                AddAzureProfileView(store: store)
            case .addKubeContext:
                AddKubeContextView(store: store)
            case .editProfile(let profile):
                switch profile.provider {
                case .aws: AddAWSProfileView(store: store, mode: .edit(profile))
                case .gcp: AddGCPProfileView(store: store, mode: .edit(profile))
                case .azure: AddAzureProfileView(store: store, mode: .edit(profile))
                case .kubernetes: AddKubeContextView(store: store, mode: .edit(profile))
                }
            case .duplicateProfile(let profile):
                switch profile.provider {
                case .aws: AddAWSProfileView(store: store, mode: .duplicate(profile))
                case .gcp: AddGCPProfileView(store: store, mode: .duplicate(profile))
                case .azure: AddAzureProfileView(store: store, mode: .duplicate(profile))
                case .kubernetes: AddKubeContextView(store: store, mode: .edit(profile))
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
        VStack(spacing: 0) {
            // Inline notification bars — part of the layout so they NEVER cover content
            if store.showExpirationWarning || store.updateAvailable {
                VStack(spacing: 8) {
                    if store.showExpirationWarning {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text(store.expirationWarningMessage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            // Main content flows BELOW the banners — never covered
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
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140)

                            if !activeAWS.region.isEmpty {
                                Text("· \(activeAWS.region)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            if activeAWS.status == .connected, let expiresAt = store.activeAWSExpiresAt, expiresAt > Date() {
                                SessionCountdownView(expiresAt: expiresAt)
                            }

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
                        .help("AWS \(store.activeAWSProfile) · Account \(activeAWS.accountID.isEmpty ? "—" : activeAWS.accountID) · \(activeAWS.status.rawValue)")
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
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140)

                            if !activeGCP.accountID.isEmpty {
                                Text("· \(activeGCP.accountID)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 120)
                            }

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
                        .help("GCP \(store.activeGCPProfile) · Project \(activeGCP.accountID.isEmpty ? "—" : activeGCP.accountID) · \(activeGCP.status.rawValue)")
                    }

                    if !store.activeAzureProfile.isEmpty,
                       let activeAzure = store.profiles.first(where: { $0.provider == .azure && $0.name == store.activeAzureProfile }) {
                        let statusColor = activeAzure.status.color

                        HStack(spacing: 6) {
                            Image(systemName: "triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(statusColor)

                            Text("Azure: \(store.activeAzureProfile)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140)

                            if !activeAzure.region.isEmpty {
                                Text("· \(activeAzure.region)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Divider()
                                .frame(height: 10)
                                .background(Color.secondary.opacity(0.3))

                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.logout(activeAzure)
                                }
                                .help("Disconnect active Azure subscription")
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.separator.opacity(0.15), lineWidth: 0.5)
                        }
                        .help("Azure \(store.activeAzureProfile) · Subscription \(activeAzure.accountID.isEmpty ? "—" : activeAzure.accountID) · \(activeAzure.status.rawValue)")
                    }

                    if !store.activeKubeContext.isEmpty,
                       let activeKube = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == store.activeKubeContext }) {
                        let statusColor = activeKube.status.color

                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(statusColor)

                            Text("K8s: \(store.activeKubeContext)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140)

                            Divider()
                                .frame(height: 10)
                                .background(Color.secondary.opacity(0.3))

                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.logout(activeKube)
                                }
                                .help("Clear current Kubernetes context")
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.separator.opacity(0.15), lineWidth: 0.5)
                        }
                        .help("Kubernetes context \(store.activeKubeContext) · \(activeKube.status.rawValue)")
                    }
                }
                .buttonStyle(.plain)
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if !store.activeAWSProfile.isEmpty,
                       let expiresAt = store.activeAWSExpiresAt, expiresAt > Date() {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 8, weight: .bold))
                            SessionCountdownView(expiresAt: expiresAt)
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
                        }
                        .help("AWS active session expiry countdown")
                    } else if !store.activeAWSProfile.isEmpty || !store.activeGCPProfile.isEmpty || !store.activeAzureProfile.isEmpty || !store.activeKubeContext.isEmpty {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .padding(4)
                            .background(Color.green.opacity(0.12), in: Circle())
                            .help("Connected to cloud environment")
                    }

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
                            switch folder.provider {
                            case .aws: sheet = .addAWSProfile
                            case .gcp: sheet = .addGCPProfile
                            case .azure: sheet = .addAzureProfile
                            case .kubernetes: sheet = .addKubeContext
                            }
                        } label: {
                            Label(folder.provider == .kubernetes ? "Add Context" : "Add Profile", systemImage: "plus")
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
                } else if profile.provider == .azure {
                    Text("Subscription: \(profile.accountID)  ·  Tenant: \(profile.roleName.isEmpty ? "—" : profile.roleName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profile.provider == .kubernetes {
                    Text("Kubernetes context")
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

/// A live mm:ss countdown to an AWS SSO session's expiry, shown in the toolbar.
struct SessionCountdownView: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: 8, weight: .bold))
                Text(String(format: "%02d:%02d", minutes, seconds))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(remaining <= 120 ? Color.orange : Color.secondary)
            .help("Active AWS session expires in \(minutes)m \(seconds)s")
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

