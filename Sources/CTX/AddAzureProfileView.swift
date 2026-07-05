import CTXCore
import SwiftUI

enum AzureProfileEditorMode {
    case create
    case edit(CloudProfile)
    case duplicate(CloudProfile)

    var title: String {
        switch self {
        case .create:
            "Add Azure Subscription"
        case .edit:
            "Edit Azure Subscription"
        case .duplicate:
            "Duplicate Azure Subscription"
        }
    }

    var actionTitle: String {
        switch self {
        case .create:
            "Create"
        case .edit:
            "Save"
        case .duplicate:
            "Duplicate"
        }
    }

    var draft: AzureProfileDraft {
        switch self {
        case .create:
            AzureProfileDraft()
        case .edit(let profile):
            AzureProfileDraft(profile: profile)
        case .duplicate(let profile):
            AzureProfileDraft(profile: profile, duplicate: true)
        }
    }
}

struct AddAzureProfileView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: AzureProfileEditorMode
    let targetFolder: CloudFolder?
    @State private var draft: AzureProfileDraft
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: AzureProfileEditorMode = .create, targetFolder: CloudFolder? = nil) {
        self.store = store
        self.mode = mode
        self.targetFolder = targetFolder
        self._draft = State(initialValue: mode.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.weight(.semibold))
                Text("Register an Azure subscription so CTX can switch to it with `az account set`.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Form {
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
            .frame(height: 260)

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

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(CTXSecondaryButton())
                .keyboardShortcut(.cancelAction)

                Button(mode.actionTitle) {
                    save()
                }
                .buttonStyle(CTXPrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
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
                try store.addAzureProfile(draft, targetFolder: targetFolder)
            case .edit(let profile):
                try store.updateAzureProfile(profile, draft: draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
