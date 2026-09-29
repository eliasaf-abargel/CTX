import CTXCore
import SwiftUI

public enum KubeContextAuthMode: String, CaseIterable, Identifiable, Sendable {
    case cloudIAM = "AWS EKS (IAM / SSO)"
    case strongDM = "StrongDM (SDM)"
    case teleport = "Teleport (tsh)"
    case gcpGKE = "Google GKE"
    case azureAKS = "Azure AKS"
    case bearerToken = "Bearer Token"
    case proxyTunnel = "Local Proxy / Direct"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .cloudIAM: "cloud.fill"
        case .strongDM: "network.badge.shield.half.filled"
        case .teleport: "lock.shield.fill"
        case .gcpGKE: "globe"
        case .azureAKS: "triangle.fill"
        case .bearerToken: "key.fill"
        case .proxyTunnel: "server.rack"
        }
    }
}

struct AddKubeContextDetailsSections: View {
    @ObservedObject var store: ProfileStore
    @Binding var selectedFolder: CloudFolder?
    @Binding var name: String
    @Binding var namespace: String
    @Binding var server: String
    @Binding var cluster: String
    let isResolvingServer: Bool
    let isDuplicating: Bool

    var body: some View {
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
                .disabled(isDuplicating)
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
        .disabled(isDuplicating)
    }
}

struct AddKubeContextAuthSection: View {
    @Binding var authMode: KubeContextAuthMode
    @Binding var user: String
    @Binding var awsRegion: String
    @Binding var awsProfile: String
    @Binding var isReplacingBearerToken: Bool
    @Binding var token: String
    let awsProfiles: [CloudProfile]
    let isDuplicating: Bool
    let hasExistingCredential: Bool
    let showsBearerTokenField: Bool
    let isEditing: Bool

    var body: some View {
        Section("Authentication") {
            if isDuplicating {
                Text("The duplicate keeps the existing cluster and user references. Credential values are never copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Auth Provider:", selection: $authMode) {
                ForEach(KubeContextAuthMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }

            TextField("User Name:", text: $user, prompt: Text("e.g. my-user (optional, defaults to name-user)"))
                .textFieldStyle(.roundedBorder)

            switch authMode {
            case .cloudIAM:
                LabeledContent("Provider:") {
                    Text("AWS EKS")
                }
                Text("Configures aws eks get-token with your AWS SSO profile credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                AWSRegionPickerView(selection: $awsRegion, label: "AWS Region:")

                Picker("AWS Profile:", selection: $awsProfile) {
                    Text("Default AWS credentials").tag("")
                    ForEach(awsProfiles, id: \.name) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }

            case .strongDM:
                HStack(spacing: 6) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .foregroundStyle(.orange)
                    Text("Routes traffic through StrongDM local proxy (SDM Desktop App or CLI).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

            case .teleport:
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.purple)
                    Text("Authenticates using Teleport Zero-Trust Gateway (tsh kube login).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

            case .gcpGKE:
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .foregroundStyle(.blue)
                    Text("Authenticates using Google Cloud SDK / gke-gcloud-auth-plugin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

            case .azureAKS:
                HStack(spacing: 6) {
                    Image(systemName: "triangle.fill")
                        .foregroundStyle(.cyan)
                    Text("Authenticates using Azure CLI (az aks / kubelogin).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

            case .proxyTunnel:
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    Text("Uses an existing local proxy or pre-configured kubeconfig endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

            case .bearerToken:
                if hasExistingCredential {
                    Toggle("Replace existing bearer token", isOn: $isReplacingBearerToken)
                    if !isReplacingBearerToken {
                        Text("The existing credential is preserved. CTX never reads or displays its value.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showsBearerTokenField {
                    SecureField("Bearer Token:", text: $token, prompt: Text("Enter a new token"))
                        .textFieldStyle(.roundedBorder)
                    if isEditing && !hasExistingCredential {
                        Text("Enter a token to add credentials, or leave it blank to save only the other changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .disabled(isDuplicating)
    }
}
