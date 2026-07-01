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
        CloudProvider.allCases
    }

    private var visibleIcons: [CloudFolderIcon] {
        [.server, .cube, .tools, .database, .folder]
    }

    init(store: ProfileStore, folder: CloudFolder? = nil) {
        self.store = store
        self.folder = folder
        self._name = State(initialValue: folder?.name ?? "")
        let initialProvider = folder?.provider ?? .aws
        self._provider = State(initialValue: initialProvider)
        self._icon = State(initialValue: folder?.icon ?? .server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(folder == nil ? "New Folder" : "Edit Folder")
                    .font(.title.weight(.semibold))
                Text("Group profiles by environment under a provider.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 22)
            
            Divider()

            VStack(alignment: .leading, spacing: 22) {
                if folder == nil {
                    Picker("", selection: $provider) {
                        ForEach(availableProviders, id: \.self) { provider in
                            Text(provider.shortName)
                                .tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder Name")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    TextField("Production", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.separator.opacity(0.25), lineWidth: 1)
                        }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Icon")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        ForEach(visibleIcons) { iconItem in
                            let isSelected = self.icon == iconItem
                            Button {
                                self.icon = iconItem
                            } label: {
                                FolderIconSwatch(icon: iconItem, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel(iconItem.rawValue)
                        }
                    }
                }
            }
            .padding(24)

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
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

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
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 540)
        .background(.regularMaterial)
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
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let folder {
                try store.updateFolder(folder, name: trimmedName, icon: icon)
            } else {
                try store.addFolder(name: trimmedName, provider: provider, icon: icon)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FolderIconSwatch: View {
    let icon: CloudFolderIcon
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Image(systemName: icon.systemImage)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 64, height: 54)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                shape.fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.10))
            }
            .overlay {
                shape.stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 10, y: 4)
    }
}
