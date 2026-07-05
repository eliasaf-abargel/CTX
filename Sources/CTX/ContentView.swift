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
            case .selectProvider:
                SelectProviderView(sheet: $sheet)
            case .addAWSProfile:
                AddAWSProfileView(store: store)
            case .addGCPProfile:
                AddGCPProfileView(store: store)
            case .addAzureProfile:
                AddAzureProfileView(store: store)
            case .addKubeContext:
                AddKubeContextView(
                    store: store,
                    targetFolder: store.selectedFolder?.provider == .kubernetes ? store.selectedFolder : nil
                )
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
        .alert(
            "Connection Failed",
            isPresented: Binding(
                get: { store.connectionErrorMessage != nil },
                set: { if !$0 { store.connectionErrorMessage = nil } }
            ),
            presenting: store.connectionErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
        .onChange(of: store.triggerSheet) { _, newValue in
            if let newValue {
                switch newValue {
                case .addAWSProfile: sheet = .addAWSProfile
                case .addGCPProfile: sheet = .addGCPProfile
                case .addAzureProfile: sheet = .addAzureProfile
                case .addKubeContext: sheet = .addKubeContext
                }
                store.triggerSheet = nil
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

struct DetailPane: View {
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction

    private var activeToolbarProfiles: [CloudProfile] {
        [
            (.aws, store.activeAWSProfile),
            (.gcp, store.activeGCPProfile),
            (.azure, store.activeAzureProfile),
            (.kubernetes, store.activeKubeContext)
        ].compactMap { provider, name in
            guard !name.isEmpty else { return nil }
            return store.profiles.first { $0.provider == provider && $0.name == name }
        }
    }

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

            // Active profiles list (stacked vertically, row by row / line by line)
            if !activeToolbarProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACTIVE CONNECTIONS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    ForEach(activeToolbarProfiles) { profile in
                        ActiveConnectionRow(
                            profile: profile,
                            expiresAt: store.sessionExpiry(for: profile),
                            store: store
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
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

    }
}

private struct ActiveToolbarCard: View {
    let profile: CloudProfile
    let expiresAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .shadow(color: .green.opacity(0.45), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(profile.provider.shortName) \(profile.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !profile.contextSubtitle.isEmpty {
                    Text(profile.contextSubtitle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let expiresAt, expiresAt > Date() {
                Spacer(minLength: 8)
                SessionCountdownView(expiresAt: expiresAt, tintColor: profile.provider.tint, fontSize: 13)
            }
        }
        .foregroundStyle(profile.provider.tint)
        .padding(.horizontal, 12)
        .frame(width: 250, height: 44, alignment: .leading)
        .background(profile.provider.tint.opacity(0.16), in: Capsule())
        .overlay {
            Capsule()
                .stroke(profile.provider.tint.opacity(0.36), lineWidth: 0.75)
        }
    }
}

struct FolderDetailView: View {
    let folder: CloudFolder
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?

    var body: some View {
        ScrollView {
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
                    .buttonStyle(CTXPrimaryButton())
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
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(32)
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
                    
                    if profile.status == .connected {
                        if let expiresAt = store.sessionExpiry(for: profile) {
                            SessionCountdownView(expiresAt: expiresAt, tintColor: .green, fontSize: 9)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .foregroundColor(.green)
                                .overlay {
                                    Capsule()
                                        .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                                }
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                    .font(.system(size: 7, weight: .bold))
                                Text("Connected")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                            }
                        }
                    } else if profile.status.isBusy {
                        HStack(spacing: 3) {
                            Image(systemName: profile.status.systemImage)
                                .font(.system(size: 7, weight: .bold))
                            Text(profile.status.rawValue)
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(profile.status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(profile.status.color.opacity(0.12), in: Capsule())
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
                if profile.status.isBusy {
                    Button(profile.status.rawValue) {}
                        .buttonStyle(CTXSecondaryButton())
                        .disabled(true)
                } else if profile.status == .connected {
                    Button("Disconnect") {
                        store.logout(profile)
                    }
                    .buttonStyle(CTXSecondaryButton())
                } else {
                    Button("Connect") {
                        store.login(profile)
                    }
                    .buttonStyle(CTXPrimaryButton())
                }

                if !store.isActive(profile) {
                    Button("Activate") {
                        store.setActive(profile)
                    }
                    .buttonStyle(CTXSecondaryButton())
                }

                Button {
                    sheet = .editProfile(profile)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(CTXSecondaryButton())
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
    var tintColor: Color? = nil
    var fontSize: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            let seconds = Int(remaining) % 60
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: fontSize - 2, weight: .bold))
                if hours > 0 {
                    Text(String(format: "%d:%02d:%02d", hours, minutes, seconds))
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                } else {
                    Text(String(format: "%02d:%02d", minutes, seconds))
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(tintColor ?? (remaining <= 120 ? Color.orange : Color.secondary))
            .help(hours > 0 ? "Active AWS session expires in \(hours)h \(minutes)m" : "Active AWS session expires in \(minutes)m \(seconds)s")
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
        .background(Color.clear)
    }
}

private struct ActiveConnectionRow: View {
    let profile: CloudProfile
    let expiresAt: Date?
    @ObservedObject var store: ProfileStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .shadow(color: .green.opacity(0.45), radius: 3)

            Text(profile.provider.compactName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(profile.provider.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(profile.provider.tint.opacity(0.12), in: Capsule())

            Text(profile.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if !profile.contextSubtitle.isEmpty {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(profile.contextSubtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let expiresAt, expiresAt > Date() {
                Spacer(minLength: 8)
                SessionCountdownView(expiresAt: expiresAt, tintColor: profile.provider.tint, fontSize: 11)
            }

            Spacer()

            Button {
                store.logout(profile)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Disconnect active profile")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.15), lineWidth: 0.5)
        }
    }
}

struct SelectProviderView: View {
    @Binding var sheet: SidebarSheet?

    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 4) {
                Text("New Profile")
                    .font(.title3.weight(.bold))
                Text("Select a cloud provider to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            // List of Providers
            VStack(spacing: 8) {
                providerButton(
                    name: "Amazon Web Services (AWS)",
                    provider: .aws,
                    target: .addAWSProfile
                )

                providerButton(
                    name: "Google Cloud Platform (GCP)",
                    provider: .gcp,
                    target: .addGCPProfile
                )

                providerButton(
                    name: "Microsoft Azure",
                    provider: .azure,
                    target: .addAzureProfile
                )

                providerButton(
                    name: "Kubernetes (K8s)",
                    provider: .kubernetes,
                    target: .addKubeContext
                )
            }
            .padding(.top, 4)

            Divider()
                .padding(.top, 4)

            HStack {
                Spacer()
                Button("Cancel") {
                    sheet = nil
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func providerButton(
        name: String,
        provider: CloudProvider,
        target: SidebarSheet
    ) -> some View {
        Button {
            sheet = nil
            // Prevent sheet collision by presenting on next runloop cycle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                sheet = target
            }
        } label: {
            HStack(spacing: 12) {
                ProviderIcon(
                    provider: provider,
                    size: 16,
                    fallbackTint: provider.tint
                )
                .frame(width: 26, height: 26)
                .background(provider.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.12), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .focusable(false) // Prevents the blue focus ring glitch!
    }
}
