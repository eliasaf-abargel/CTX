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
    case proxyTunnel = "Zero-Trust / Proxy"
    case cloudIAM = "Cloud IAM"
    case bearerToken = "Bearer Token"

    var id: String { rawValue }
}

private enum KubeCloudIAMProvider: String, CaseIterable, Identifiable {
    case awsEKS = "AWS EKS"
    case gcpGKE = "Google GKE"
    case azureAKS = "Azure AKS"

    var id: String { rawValue }
}

struct AddKubeContextView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: KubeContextEditorMode
    let targetFolder: CloudFolder?

    @State private var selectedFolder: CloudFolder?
    @State private var name = ""
    @State private var server = ""
    @State private var cluster = ""
    @State private var user = ""
    @State private var namespace = ""
    @State private var token = ""
    @State private var authMode: KubeContextAuthMode = .proxyTunnel
    @State private var cloudProvider: KubeCloudIAMProvider = .awsEKS
    @State private var awsRegion = "us-east-1"
    @State private var awsProfile = ""
    @State private var gcpConfig = ""
    @State private var azureSub = ""
    @State private var isResolvingServer = false
    @State private var isSaving = false
    @State private var errorMessage = ""

    init(store: ProfileStore, mode: KubeContextEditorMode = .create, targetFolder: CloudFolder? = nil) {
        self.store = store
        self.mode = mode
        self.targetFolder = targetFolder
        let kubeFolders = store.folders(for: .kubernetes)
        self._selectedFolder = State(initialValue: targetFolder ?? kubeFolders.first)
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
                Section("Organization & Folder") {
                    Picker("Folder / Environment:", selection: $selectedFolder) {
                        ForEach(store.folders(for: .kubernetes)) { folder in
                            Label(folder.name, systemImage: folder.icon.systemImage)
                                .tag(Optional(folder))
                        }
                    }
                }

                Section("Context Settings") {
                    TextField("Context Name:", text: $name, prompt: Text("e.g. dev-k8s"))
                        .textFieldStyle(.roundedBorder)
                    
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

                    switch authMode {
                    case .proxyTunnel:
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.blue)
                            Text("Session identity managed automatically via local proxy tunnel (StrongDM, Teleport, Boundary, or local gateway).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)

                    case .cloudIAM:
                        Picker("Cloud Provider:", selection: $cloudProvider) {
                            ForEach(KubeCloudIAMProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)

                        if cloudProvider == .awsEKS {
                            AWSRegionPickerView(selection: $awsRegion, label: "AWS Region:")

                            Picker("AWS Profile:", selection: $awsProfile) {
                                Text("Default AWS credentials").tag("")
                                ForEach(awsProfiles, id: \.name) { profile in
                                    Text(profile.name).tag(profile.name)
                                }
                            }
                        } else if cloudProvider == .gcpGKE {
                            Picker("GCP Configuration:", selection: $gcpConfig) {
                                Text("Active gcloud configuration").tag("")
                                ForEach(gcpProfiles, id: \.name) { profile in
                                    Text(profile.name).tag(profile.name)
                                }
                            }
                        } else if cloudProvider == .azureAKS {
                            Picker("Azure Subscription:", selection: $azureSub) {
                                Text("Active Azure subscription").tag("")
                                ForEach(azureProfiles, id: \.name) { profile in
                                    Text(profile.name).tag(profile.name)
                                }
                            }
                        }

                    case .bearerToken:
                        SecureField("Bearer Token:", text: $token, prompt: Text("Token string (optional)"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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
        .onChange(of: name) { _, newName in
            autoDetectAuthMode(from: newName)
        }
        .onChange(of: cluster) { _, newCluster in
            autoDetectAuthMode(from: newCluster)
        }
        .onChange(of: server) { _, newServer in
            autoDetectAuthMode(from: newServer)
            if authMode == .cloudIAM && cloudProvider == .awsEKS, awsRegion.isEmpty {
                awsRegion = Self.eksRegion(from: newServer)
            }
        }
        .onChange(of: authMode) { _, newValue in
            if newValue == .cloudIAM {
                if awsProfile.isEmpty {
                    awsProfile = store.activeAWSProfile
                }
                if awsRegion.isEmpty {
                    awsRegion = Self.eksRegion(from: server)
                }
            }
        }
    }

    private func autoDetectAuthMode(from text: String) {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return }

        if lower.contains("arn:aws:eks") || lower.contains("eks") {
            authMode = .cloudIAM
            cloudProvider = .awsEKS
            let region = Self.eksRegion(from: text)
            if !region.isEmpty {
                awsRegion = region
            }
        } else if lower.contains("gke") || lower.contains("googleapis") {
            authMode = .cloudIAM
            cloudProvider = .gcpGKE
        } else if lower.contains("azmk8s") || lower.contains("azure") || lower.contains("aks") {
            authMode = .cloudIAM
            cloudProvider = .azureAKS
        } else if lower.contains("sdm") || lower.contains("teleport") || lower.contains("tsh") {
            authMode = .proxyTunnel
        }
    }


    private var awsProfiles: [CloudProfile] {
        store.profiles
            .filter { $0.provider == .aws }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var gcpProfiles: [CloudProfile] {
        store.profiles
            .filter { $0.provider == .gcp }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var azureProfiles: [CloudProfile] {
        store.profiles
            .filter { $0.provider == .azure }
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

            if profile.provider == .aws || cluster.contains("arn:aws:eks") || name.lowercased().contains("eks") {
                authMode = .cloudIAM
                cloudProvider = .awsEKS
                awsProfile = profile.roleName.isEmpty ? store.activeAWSProfile : profile.roleName
                awsRegion = Self.eksRegion(from: cluster)
            } else if !profile.token.isEmpty {
                authMode = .bearerToken
                token = profile.token
            }
            
            // Resolve server endpoint dynamically
            if !cluster.isEmpty {
                isResolvingServer = true
                Task {
                    let resolved = await store.resolveKubeServer(for: cluster, contextName: profile.name)
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
                    case .proxyTunnel:
                        .internalProxy
                    case .bearerToken:
                        .bearerToken(token.isEmpty ? nil : token)
                    case .cloudIAM:
                        switch cloudProvider {
                        case .awsEKS:
                            .awsEKS(
                                region: awsRegion.trimmingCharacters(in: .whitespaces),
                                profile: awsProfile.trimmingCharacters(in: .whitespaces)
                            )
                        case .gcpGKE:
                            .internalProxy
                        case .azureAKS:
                            .internalProxy
                        }
                    }

                    try await store.addKubeContext(
                        name: name.trimmingCharacters(in: .whitespaces),
                        server: server.trimmingCharacters(in: .whitespaces),
                        cluster: cluster.trimmingCharacters(in: .whitespaces),
                        user: user.trimmingCharacters(in: .whitespaces),
                        namespace: namespace.trimmingCharacters(in: .whitespaces),
                        credential: credential,
                        targetFolder: selectedFolder
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
                    if let selectedFolder {
                        store.move(profile, to: selectedFolder)
                    }
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
