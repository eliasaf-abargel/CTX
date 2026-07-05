import CTXCore
import SwiftUI

/// Inspection detail sheet for a Kubernetes context. Contexts are discovered
/// from `~/.kube/config` (not authored in CTX), so this explains that and
/// offers a refresh rather than editable fields.
struct KubernetesContextSheet: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let profile: CloudProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kubernetes Context")
                    .font(.title2.weight(.semibold))
                Text("Contexts are read from ~/.kube/config. Switch to one with the toggle in the sidebar — CTX runs `kubectl config use-context`.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Form {
                Section("Context") {
                    LabeledContent("Name", value: profile.name)
                    LabeledContent("Status", value: profile.status.rawValue)
                    LabeledContent("Active", value: store.isActive(profile) ? "Yes" : "No")
                }
            }
            .formStyle(.grouped)
            .frame(height: 160)

            HStack {
                Button("Reload from kubeconfig") {
                    store.refresh()
                }
                .buttonStyle(CTXSecondaryButton())

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(CTXPrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
