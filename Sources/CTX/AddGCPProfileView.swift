import CTXCore
import SwiftUI

typealias GCPProfileEditorMode = ProfileEditorMode

extension ProfileEditorMode {
    /// The draft this editor starts from: empty for a new profile, a copy of the
    /// existing one for an edit, and a renamed copy for a duplicate.
    var gCPProfileDraft: GCPProfileDraft {
        switch self {
        case .create: GCPProfileDraft()
        case .edit(let profile): GCPProfileDraft(profile: profile)
        case .duplicate(let profile): GCPProfileDraft(profile: profile, duplicate: true)
        }
    }
}

struct AddGCPProfileView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: GCPProfileEditorMode
    let targetFolder: CloudFolder?
    @State private var selectedFolder: CloudFolder?
    @State private var draft: GCPProfileDraft
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: GCPProfileEditorMode = .create, targetFolder: CloudFolder? = nil) {
        self.store = store
        self.mode = mode
        self.targetFolder = targetFolder
        self._draft = State(initialValue: mode.gCPProfileDraft)
        let gcpFolders = store.folders(for: .gcp)
        self._selectedFolder = State(initialValue: targetFolder ?? gcpFolders.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title(noun: "GCP Configuration"))
                    .font(.title2.weight(.semibold))
                Text("Configure GCP settings saved to your local gcloud configuration file config_\(draft.name.isEmpty ? "<name>" : draft.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Divider()

            Form {
                Section("Organization & Folder") {
                    Picker("Folder / Environment:", selection: $selectedFolder) {
                        ForEach(store.folders(for: .gcp)) { folder in
                            Label(folder.name, systemImage: folder.icon.systemImage)
                                .tag(Optional(folder))
                        }
                    }
                }

                Section("Configuration Identity") {
                    TextField("Config Name:", text: $draft.name, prompt: Text("e.g. dev-gcp"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditing)
                    
                    TextField("Project ID:", text: $draft.project, prompt: Text("e.g. example-project-123456"))
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Account Email:", text: $draft.account, prompt: Text("e.g. user@example.com"))
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("Compute Settings") {
                    TextField("Compute Region:", text: $draft.region, prompt: Text("e.g. us-central1 (optional)"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 260)

            ProfileEditorErrorBanner(message: errorMessage)

            // Footer Actions
            ProfileEditorFooter(
                actionTitle: mode.actionTitle,
                cancel: { dismiss() },
                confirm: { save() }
            )
        }
        .padding(24)
        .frame(width: 400)
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private func save() {
        do {
            switch mode {
            case .create, .duplicate:
                try store.addGCPProfile(draft, targetFolder: selectedFolder)
            case .edit(let profile):
                try store.updateGCPProfile(profile, draft: draft)
                if let selectedFolder {
                    store.move(profile, to: selectedFolder)
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
