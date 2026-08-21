import CTXCore
import SwiftUI

/// The parts every profile editor sheet shares.
///
/// The AWS, GCP, Azure and Kubernetes editors each carried their own byte-identical
/// copy of the error banner and the Cancel/confirm footer, and their own copy of the
/// create/edit/duplicate mode enum. Only the form fields in between actually differ.
struct ProfileEditorErrorBanner: View {
    let message: String

    var body: some View {
        if !message.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .help(message)
        }
    }
}

struct ProfileEditorFooter: View {
    let actionTitle: String
    var isBusy = false
    var isConfirmDisabled = false
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .buttonStyle(CTXSecondaryButton())
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)

            Button(action: confirm) {
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(actionTitle)
                    }
                } else {
                    Text(actionTitle)
                }
            }
            .buttonStyle(CTXPrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || isConfirmDisabled)
        }
    }
}

/// Create / edit / duplicate, shared by every editor.
enum ProfileEditorMode: Equatable {
    case create
    case edit(CloudProfile)
    case duplicate(CloudProfile)

    var actionTitle: String {
        switch self {
        case .create: "Create"
        case .edit: "Save"
        case .duplicate: "Duplicate"
        }
    }

    var isEditing: Bool {
        if case .edit = self { return true }
        return false
    }

    var profile: CloudProfile? {
        switch self {
        case .create: nil
        case .edit(let profile), .duplicate(let profile): profile
        }
    }

    /// "Add/Edit/Duplicate <noun>", e.g. "Edit GCP Configuration".
    func title(noun: String) -> String {
        switch self {
        case .create: "Add \(noun)"
        case .edit: "Edit \(noun)"
        case .duplicate: "Duplicate \(noun)"
        }
    }
}
