import CTXCore
import SwiftUI

struct FolderEditorView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let folder: CloudFolder?
    
    @State private var name: String
    @State private var provider: CloudProvider
    @State private var icon: CloudFolderIcon
    @State private var errorMessage = ""
    @State private var showingDeleteAlert = false

    private var availableProviders: [CloudProvider] {
        let activeProviders = Set(store.profiles.map(\.provider))
        if activeProviders.isEmpty {
            return [.aws]
        }
        return Array(activeProviders).sorted(by: { $0.rawValue < $1.rawValue })
    }

    init(store: ProfileStore, folder: CloudFolder? = nil) {
        self.store = store
        self.folder = folder
        self._name = State(initialValue: folder?.name ?? "")
        let initialProvider = folder?.provider ?? Set(store.profiles.map(\.provider)).first ?? .aws
        self._provider = State(initialValue: initialProvider)
        self._icon = State(initialValue: folder?.icon ?? .folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(folder == nil ? "Create Folder" : "Edit Folder")
                    .font(.title2.weight(.semibold))
                Text("Choose a name and icon for this environment")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Divider()

            // Form Content
            VStack(spacing: 16) {
                // Provider Selection (Only for Create Mode)
                if folder == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROVIDER")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        
                        Picker("", selection: $provider) {
                            ForEach(availableProviders, id: \.self) { provider in
                                Text(provider.rawValue)
                                    .tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                // Folder Name input field
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    
                    TextField("Folder Name", text: $name, prompt: Text("e.g. Production, Staging, Client A"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }
                
                // Icon Picker Grid (2x5 Grid matching the mockup)
                VStack(alignment: .leading, spacing: 6) {
                    Text("ICON")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(CloudFolderIcon.allCases) { iconItem in
                            let isSelected = self.icon == iconItem
                            Button {
                                self.icon = iconItem
                            } label: {
                                Image(systemName: iconItem.systemImage)
                                    .font(.system(size: 16))
                                    .frame(width: 58, height: 46)
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .background(isSelected ? Color.accentColor : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Error banner
            if !errorMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // Footer Actions
            HStack {
                if folder != nil {
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.regular)
                }
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Button(folder == nil ? "Create" : "Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
        }
        .padding(24)
        .frame(width: 380)
        .alert("Delete Folder?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let folder {
                    store.deleteFolder(folder)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this folder? The profiles inside will not be deleted.")
        }
    }

    private func save() {
        do {
            if let folder {
                try store.updateFolder(folder, name: name, icon: icon)
            } else {
                try store.addFolder(name: name, provider: provider, icon: icon)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
