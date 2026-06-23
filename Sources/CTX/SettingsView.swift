import CTXCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @State private var editingFolder: CloudFolder?

    var body: some View {
        TabView(selection: $store.selectedSettingsTab) {
            Form {
                Section("AWS Environment") {
                    LabeledContent("Config Path") {
                        HStack(spacing: 8) {
                            Text(AWSConfigPaths.configURL.path)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            
                            Button {
                                copyToClipboard(AWSConfigPaths.configURL.path)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Copy config file path")

                            Button {
                                NSWorkspace.shared.selectFile(AWSConfigPaths.configURL.path, inFileViewerRootedAtPath: "")
                            } label: {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Reveal config file in Finder")
                        }
                    }
                    LabeledContent("Active Profile", value: store.activeAWSProfile.isEmpty ? "None" : store.activeAWSProfile)
                    LabeledContent("Total Profiles", value: "\(store.profiles.filter { $0.provider == .aws }.count)")
                }

                Section("GCP Environment") {
                    LabeledContent("Configurations Path") {
                        HStack(spacing: 8) {
                            Text(GCPConfigPaths.configurationsDirURL.path)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            
                            Button {
                                copyToClipboard(GCPConfigPaths.configurationsDirURL.path)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Copy configurations path")

                            Button {
                                NSWorkspace.shared.selectFile(GCPConfigPaths.configurationsDirURL.path, inFileViewerRootedAtPath: "")
                            } label: {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Reveal configurations in Finder")
                        }
                    }
                    LabeledContent("Active Config", value: store.activeGCPProfile.isEmpty ? "None" : store.activeGCPProfile)
                    LabeledContent("Total Configurations", value: "\(store.profiles.filter { $0.provider == .gcp }.count)")
                }

                Section("Folders Info") {
                    LabeledContent("Custom Folders", value: "\(store.allFolders.filter(\.isCustom).count)")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cloud Config", systemImage: "cloud")
            }
            .tag(0)

            List {
                Section {
                    ForEach(store.groupedProfiles.map(\.folder)) { folder in
                        HStack {
                            Label {
                                Text("\(folder.provider.rawValue) · \(folder.name)")
                                    .font(.body)
                            } icon: {
                                Image(systemName: folder.icon.systemImage)
                                    .foregroundColor(.accentColor)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 12) {
                                Button {
                                    editingFolder = folder
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

            Form {
                Section("Application Info") {
                    LabeledContent("Name", value: "CTX")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Developer", value: "Eliasaf Abargel")
                    
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
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
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
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
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
        .frame(width: 520, height: 340)
        .sheet(item: $editingFolder) { folder in
            FolderEditorView(store: store, folder: folder)
        }
        .onAppear {
            store.checkForUpdates()
        }
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
