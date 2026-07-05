import CTXCore
import SwiftUI

enum KubeContextEditorMode {
    case create
    case edit(CloudProfile)

    var title: String {
        switch self {
        case .create:
            "Add Kubernetes Context"
        case .edit:
            "Edit Kubernetes Context"
        }
    }

    var actionTitle: String {
        switch self {
        case .create:
            "Create"
        case .edit:
            "Save"
        }
    }
}

struct AddKubeContextView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: KubeContextEditorMode

    @State private var name = ""
    @State private var server = ""
    @State private var cluster = ""
    @State private var user = ""
    @State private var namespace = ""
    @State private var token = ""
    @State private var isResolvingServer = false
    @State private var isSaving = false
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: KubeContextEditorMode = .create) {
        self.store = store
        self.mode = mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.weight(.semibold))
                Text("Configure context, cluster and authentication saved to your ~/.kube/config file.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Form {
                Section("Context Settings") {
                    TextField("Context Name:", text: $name, prompt: Text("e.g. dev-k8s"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditing)
                    
                    TextField("Namespace:", text: $namespace, prompt: Text("e.g. default (optional)"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Cluster Settings") {
                    HStack(spacing: 8) {
                        TextField("API Server URL:", text: $server, prompt: Text("e.g. https://127.0.0.1:8443 or EKS endpoint"))
                            .textFieldStyle(.roundedBorder)
                        
                        if isResolvingServer {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    TextField("Cluster Name:", text: $cluster, prompt: Text("e.g. my-cluster (optional, defaults to name-cluster)"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Authentication") {
                    TextField("User Name:", text: $user, prompt: Text("e.g. my-user (optional, defaults to name-user)"))
                        .textFieldStyle(.roundedBorder)
                    
                    SecureField("Token:", text: $token, prompt: Text("Bearer token (optional)"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .frame(height: 320)

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
                .disabled(isSaving)

                Button(mode.actionTitle) {
                    save()
                }
                .buttonStyle(CTXPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty || server.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            setupInitialValues()
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private func setupInitialValues() {
        switch mode {
        case .create:
            break
        case .edit(let profile):
            name = profile.name
            cluster = profile.accountID // accountID is cluster
            user = profile.roleName     // roleName is user
            namespace = profile.region  // region is namespace
            
            // Resolve server endpoint dynamically
            if !cluster.isEmpty {
                isResolvingServer = true
                Task {
                    let resolved = await store.resolveKubeServer(for: cluster)
                    await MainActor.run {
                        server = resolved
                        isResolvingServer = false
                    }
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = ""
        
        Task {
            do {
                switch mode {
                case .create:
                    try await store.addKubeContext(
                        name: name.trimmingCharacters(in: .whitespaces),
                        server: server.trimmingCharacters(in: .whitespaces),
                        cluster: cluster.trimmingCharacters(in: .whitespaces),
                        user: user.trimmingCharacters(in: .whitespaces),
                        namespace: namespace.trimmingCharacters(in: .whitespaces),
                        token: token.isEmpty ? nil : token
                    )
                case .edit(let profile):
                    try await store.updateKubeContext(
                        profile,
                        newName: name.trimmingCharacters(in: .whitespaces),
                        server: server.trimmingCharacters(in: .whitespaces),
                        cluster: cluster.trimmingCharacters(in: .whitespaces),
                        user: user.trimmingCharacters(in: .whitespaces),
                        namespace: namespace.trimmingCharacters(in: .whitespaces),
                        token: token.isEmpty ? nil : token
                    )
                }
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
