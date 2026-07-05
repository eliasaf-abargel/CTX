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

private enum KubeContextAuthMode: String, CaseIterable, Identifiable {
    case internalProxy = "Internal"
    case bearerToken = "Bearer token"
    case awsEKS = "AWS EKS"

    var id: String { rawValue }
}

struct AddKubeContextView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: KubeContextEditorMode
    let targetFolder: CloudFolder?

    @State private var name = ""
    @State private var server = ""
    @State private var cluster = ""
    @State private var user = ""
    @State private var namespace = ""
    @State private var token = ""
    @State private var authMode: KubeContextAuthMode = .bearerToken
    @State private var awsRegion = ""
    @State private var awsProfile = ""
    @State private var isResolvingServer = false
    @State private var isSaving = false
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: KubeContextEditorMode = .create, targetFolder: CloudFolder? = nil) {
        self.store = store
        self.mode = mode
        self.targetFolder = targetFolder
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
                    Picker("Auth Mode:", selection: $authMode) {
                        ForEach(KubeContextAuthMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("User Name:", text: $user, prompt: Text("e.g. my-user (optional, defaults to name-user)"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(authMode == .internalProxy)

                    if authMode == .awsEKS {
                        TextField("AWS Region:", text: $awsRegion, prompt: Text("e.g. us-east-1"))
                            .textFieldStyle(.roundedBorder)
                        Picker("AWS Profile:", selection: $awsProfile) {
                            Text("Default AWS credentials").tag("")
                            ForEach(awsProfiles, id: \.name) { profile in
                                Text(profile.name).tag(profile.name)
                            }
                        }
                    } else {
                        SecureField("Token:", text: $token, prompt: Text("Bearer token (optional)"))
                            .textFieldStyle(.roundedBorder)
                            .disabled(authMode == .internalProxy)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 380)

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
        .onChange(of: server) { _, newValue in
            if authMode == .awsEKS, awsRegion.isEmpty {
                awsRegion = Self.eksRegion(from: newValue)
            }
        }
        .onChange(of: authMode) { _, newValue in
            if newValue == .awsEKS {
                if awsProfile.isEmpty {
                    awsProfile = store.activeAWSProfile
                }
                if awsRegion.isEmpty {
                    awsRegion = Self.eksRegion(from: server)
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private var awsProfiles: [CloudProfile] {
        store.profiles
            .filter { $0.provider == .aws }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func setupInitialValues() {
        switch mode {
        case .create:
            awsProfile = store.activeAWSProfile
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
                    let credential: KubeConfigCredential = switch authMode {
                    case .internalProxy:
                        .internalProxy
                    case .bearerToken:
                        .bearerToken(token.isEmpty ? nil : token)
                    case .awsEKS:
                        .awsEKS(
                            region: awsRegion.trimmingCharacters(in: .whitespaces),
                            profile: awsProfile.trimmingCharacters(in: .whitespaces)
                        )
                    }

                    try await store.addKubeContext(
                        name: name.trimmingCharacters(in: .whitespaces),
                        server: server.trimmingCharacters(in: .whitespaces),
                        cluster: cluster.trimmingCharacters(in: .whitespaces),
                        user: user.trimmingCharacters(in: .whitespaces),
                        namespace: namespace.trimmingCharacters(in: .whitespaces),
                        credential: credential,
                        targetFolder: targetFolder
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

    private static func eksRegion(from server: String) -> String {
        guard let host = URL(string: server)?.host else { return "" }
        let parts = host.split(separator: ".").map(String.init)
        guard let eksIndex = parts.firstIndex(of: "eks"), eksIndex > 0 else { return "" }
        return parts[eksIndex - 1]
    }
}
