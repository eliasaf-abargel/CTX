import CTXCore
import SwiftUI

typealias AzureProfileEditorMode = ProfileEditorMode

extension ProfileEditorMode {
    /// The draft this editor starts from: empty for a new profile, a copy of the
    /// existing one for an edit, and a renamed copy for a duplicate.
    var azureProfileDraft: AzureProfileDraft {
        switch self {
        case .create: AzureProfileDraft()
        case .edit(let profile): AzureProfileDraft(profile: profile)
        case .duplicate(let profile): AzureProfileDraft(profile: profile, duplicate: true)
        }
    }
}

struct AddAzureProfileView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: AzureProfileEditorMode
    let targetFolder: CloudFolder?
    @State private var selectedFolder: CloudFolder?
    @State private var draft: AzureProfileDraft
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: AzureProfileEditorMode = .create, targetFolder: CloudFolder? = nil) {
        self.store = store
        self.mode = mode
        self.targetFolder = targetFolder
        self._draft = State(initialValue: mode.azureProfileDraft)
        let azureFolders = store.folders(for: .azure)
        self._selectedFolder = State(initialValue: targetFolder ?? azureFolders.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title(noun: "Azure Subscription"))
                    .font(.title2.weight(.semibold))
                Text("Register an Azure subscription so CTX can switch to it with `az account set`.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Form {
                Section("Organization & Folder") {
                    Picker("Folder / Environment:", selection: $selectedFolder) {
                        ForEach(store.folders(for: .azure)) { folder in
                            Label(folder.name, systemImage: folder.icon.systemImage)
                                .tag(Optional(folder))
                        }
                    }
                }

                Section("Subscription Identity") {
                    TextField("Display Name:", text: $draft.name, prompt: Text("e.g. sandbox-sub"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditing)

                    TextField("Subscription ID:", text: $draft.subscriptionID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                        .textFieldStyle(.roundedBorder)

                    TextField("Tenant ID (optional):", text: $draft.tenantID, prompt: Text("directory / tenant GUID"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Defaults") {
                    TextField("Default Location:", text: $draft.location, prompt: Text("e.g. westeurope (optional)"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 300)

            ProfileEditorErrorBanner(message: errorMessage)

            ProfileEditorFooter(
                actionTitle: mode.actionTitle,
                cancel: { dismiss() },
                confirm: { save() }
            )
        }
        .padding(24)
        .frame(width: 420)
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
                try store.addAzureProfile(draft, targetFolder: selectedFolder)
            case .edit(let profile):
                try store.updateAzureProfile(profile, draft: draft)
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
