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
                Text("Organize profiles into folders to group environments or clients together.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Divider()

            Form {
                Section("Folder Identity") {
                    TextField("Folder Name:", text: $name, prompt: Text("e.g. Production, Client A"))
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("Settings") {
                    Picker("Provider:", selection: $provider) {
                        ForEach(availableProviders, id: \.self) { provider in
                            Label(provider.rawValue, systemImage: provider.systemImage)
                                .tag(provider)
                        }
                    }
                    .disabled(folder != nil)

                    Picker("Folder Icon:", selection: $icon) {
                        ForEach(CloudFolderIcon.allCases) { icon in
                            Label(icon.rawValue.capitalized, systemImage: icon.systemImage)
                                .tag(icon)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 200)

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

            // Footer Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button(folder == nil ? "Create" : "Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
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
