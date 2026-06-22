import CTXCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @State private var editingFolder: CloudFolder?

    var body: some View {
        TabView {
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
                    LabeledContent("Total Profiles", value: "\(store.profiles.count)")
                    LabeledContent("Custom Folders", value: "\(store.allFolders.filter(\.isCustom).count)")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cloud Config", systemImage: "cloud")
            }

            // Folders Management Tab
            List {
                Section("Manage Folders") {
                    ForEach(store.allFolders) { folder in
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
                                
                                if folder.isCustom {
                                    Button {
                                        store.deleteFolder(folder)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete folder")
                                } else {
                                    // Placeholder spacing
                                    Image(systemName: "trash")
                                        .opacity(0)
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset)
            .tabItem {
                Label("Folders", systemImage: "folder")
            }

            Form {
                Section("Application Info") {
                    LabeledContent("Name", value: "CTX")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Developer", value: "Eliasaf Abargel")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .scenePadding()
        .frame(width: 520, height: 340)
        .sheet(item: $editingFolder) { folder in
            FolderEditorView(store: store, folder: folder)
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
