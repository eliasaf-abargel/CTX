import CTXCore
import SwiftUI

enum GCPProfileEditorMode {
    case create
    case edit(CloudProfile)
    case duplicate(CloudProfile)

    var title: String {
        switch self {
        case .create:
            "Add GCP Configuration"
        case .edit:
            "Edit GCP Configuration"
        case .duplicate:
            "Duplicate GCP Configuration"
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

    var draft: GCPProfileDraft {
        switch self {
        case .create:
            GCPProfileDraft()
        case .edit(let profile):
            GCPProfileDraft(profile: profile)
        case .duplicate(let profile):
            GCPProfileDraft(profile: profile, duplicate: true)
        }
    }
}

struct AddGCPProfileView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: GCPProfileEditorMode
    @State private var draft: GCPProfileDraft
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: GCPProfileEditorMode = .create) {
        self.store = store
        self.mode = mode
        self._draft = State(initialValue: mode.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.weight(.semibold))
                Text("Configure GCP settings saved to your local gcloud configuration file config_\(draft.name.isEmpty ? "<name>" : draft.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Divider()

            Form {
                Section("Configuration Identity") {
                    TextField("Config Name:", text: $draft.name, prompt: Text("e.g. dev-gcp"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditing)
                    
                    TextField("Project ID:", text: $draft.project, prompt: Text("e.g. support-prod-157422"))
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
            .frame(height: 220)

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
                try store.addGCPProfile(draft)
            case .edit(let profile):
                try store.updateGCPProfile(profile, draft: draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
