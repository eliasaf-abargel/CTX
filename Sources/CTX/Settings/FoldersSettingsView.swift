import CTXCore
import SwiftUI

struct FoldersSettingsView: View {
    @ObservedObject var store: ProfileStore
    @State private var editingFolder: CloudFolder?

    var body: some View {
        Form {
            Section {
                ForEach(store.groupedProfiles.map(\.folder)) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: folder.icon.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)

                        Text("\(folder.provider.rawValue) · \(folder.name)")

                        Spacer()

                        Button {
                            editingFolder = folder
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("Edit folder name and icon")
                        .accessibilityLabel("Edit folder \(folder.name)")

                        Button {
                            store.deleteFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("Delete folder")
                        .accessibilityLabel("Delete folder \(folder.name)")
                    }
                }
            } header: {
                HStack {
                    Text("Manage folders")
                    Spacer()
                    if !store.hiddenFolderIDs.isEmpty {
                        Button("Restore defaults") {
                            store.restoreAllFolders()
                        }
                        .buttonStyle(.link)
                        .focusable(false)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $editingFolder) { folder in
            FolderEditorView(store: store, folder: folder)
        }
    }
}
