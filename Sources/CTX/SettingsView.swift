import CTXCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @State private var localSheet: SidebarSheet?

    var body: some View {
        TabView(selection: $store.selectedSettingsTab) {
            // Tab 0: Redesigned Cloud Config Tab (Connected Providers)
            VStack(alignment: .leading, spacing: 14) {
                Text("CONNECTED PROVIDERS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                
                VStack(spacing: 0) {
                    providerRow(
                        title: "AWS",
                        provider: .aws,
                        defaultPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws").appendingPathComponent("config").path,
                        customKey: "customAWSConfigPath",
                        countString: "\(store.profiles.filter { $0.provider == .aws }.count) profiles"
                    )
                    
                    Divider()
                        .padding(.horizontal, 16)
                    
                    providerRow(
                        title: "Google Cloud",
                        provider: .gcp,
                        defaultPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").appendingPathComponent("gcloud").appendingPathComponent("configurations").path,
                        customKey: "customGCPConfigDirPath",
                        countString: "\(store.profiles.filter { $0.provider == .gcp }.count) configurations"
                    )
                    
                    Divider()
                        .padding(.horizontal, 16)
                    
                    providerRow(
                        title: "Azure",
                        provider: .azure,
                        defaultPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").appendingPathComponent("ctx").appendingPathComponent("azure").path,
                        customKey: "customAzureProfilesDirPath",
                        countString: "\(store.profiles.filter { $0.provider == .azure }.count) subscriptions"
                    )
                    
                    Divider()
                        .padding(.horizontal, 16)
                    
                    providerRow(
                        title: "Kubernetes",
                        provider: .kubernetes,
                        defaultPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube").appendingPathComponent("config").path,
                        customKey: "customKubeconfigPath",
                        countString: "\(store.profiles.filter { $0.provider == .kubernetes }.count) contexts"
                    )
                }
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator.opacity(0.15), lineWidth: 0.5)
                }
                .padding(.horizontal, 16)
                
                HStack {
                    Spacer()
                    Menu {
                        Button("AWS Profile...") { store.triggerSheet = .addAWSProfile }
                        Button("Google Cloud Config...") { store.triggerSheet = .addGCPProfile }
                        Button("Azure Subscription...") { store.triggerSheet = .addAzureProfile }
                        Button("Kubernetes Context...") { store.triggerSheet = .addKubeContext }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Connect another provider...")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.bottom, 16)
            }
            .tabItem {
                Label("Cloud Config", systemImage: "cloud")
            }
            .tag(0)

            // Tab 1: Folders
            List {
                Section {
                    ForEach(store.groupedProfiles.map(\.folder)) { folder in
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: folder.icon.systemImage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 18)
                                
                                Text("\(folder.provider.rawValue) · \(folder.name)")
                                    .font(.body)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 12) {
                                Button {
                                    localSheet = .editFolder(folder)
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Edit folder name/icon")
                                
                                Button {
                                    store.deleteFolder(folder)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete folder")
                            }
                            .padding(.trailing, 4)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("Manage Folders")
                        Spacer()
                        if !store.hiddenFolderIDs.isEmpty {
                            Button("Restore Defaults") {
                                store.restoreAllFolders()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .tabItem {
                Label("Folders", systemImage: "folder")
            }
            .tag(1)

            // Tab 2: About
            Form {
                Section("Application Info") {
                    LabeledContent("Name", value: "CTX")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Runtime", value: "Native macOS")
                    LabeledContent("Signed in as", value: store.activeIdentityLabel)
                    
                    if store.updateAvailable {
                        LabeledContent("New Version") {
                            if store.isUpdating {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Installing...")
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button("Update to \(store.latestVersionString)") {
                                    store.installUpdate()
                                }
                                .buttonStyle(CTXPrimaryButton())
                            }
                        }
                    } else {
                        LabeledContent("Updates") {
                            HStack(spacing: 8) {
                                if store.isCheckingForUpdates {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Checking...")
                                        .foregroundColor(.secondary)
                                } else {
                                    if !store.updateCheckMessage.isEmpty {
                                        Text(store.updateCheckMessage)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Button("Check for Updates") {
                                        store.checkForUpdates(manual: true)
                                    }
                                    .buttonStyle(CTXSecondaryButton())
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
            .tag(2)
        }
        .id(store.selectedSettingsTab)
        .scenePadding()
        .frame(width: 540, height: 380)

        .sheet(item: $localSheet) { item in
            switch item {
            case .selectProvider:
                SelectProviderView(sheet: $localSheet)
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
                case .aws: AddAWSProfileView(store: store, mode: .duplicate(profile), targetFolder: store.folder(for: profile))
                case .gcp: AddGCPProfileView(store: store, mode: .duplicate(profile), targetFolder: store.folder(for: profile))
                case .azure: AddAzureProfileView(store: store, mode: .duplicate(profile), targetFolder: store.folder(for: profile))
                case .kubernetes: AddKubeContextView(store: store, mode: .edit(profile), targetFolder: store.folder(for: profile))
                }
            case .addFolder:
                FolderEditorView(store: store)
            case .editFolder(let folder):
                FolderEditorView(store: store, folder: folder)
            }
        }
        .onAppear {
            store.checkForUpdates()
        }
    }

    private func providerRow(
        title: String,
        provider: CloudProvider,
        defaultPath: String,
        customKey: String,
        countString: String
    ) -> some View {
        let currentPath = UserDefaults.standard.string(forKey: customKey) ?? defaultPath
        let displayPath = currentPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        
        return HStack(spacing: 12) {
            ProviderIcon(provider: provider, size: 16)
                .frame(width: 28, height: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                
                Button {
                    selectCustomPath(for: provider, customKey: customKey)
                } label: {
                    Text(displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .underline()
                }
                .buttonStyle(.plain)
                .focusable(false) // Prevents the blue focus ring glitch!
                .help("Click to change config path")
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Text(countString)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                if UserDefaults.standard.string(forKey: customKey) != nil {
                    Button {
                        UserDefaults.standard.removeObject(forKey: customKey)
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default path")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private func selectCustomPath(for provider: CloudProvider, customKey: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = (provider != .gcp && provider != .azure)
        panel.canChooseDirectories = (provider == .gcp || provider == .azure)
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: customKey)
            store.refresh()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
