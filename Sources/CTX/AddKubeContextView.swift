import CTXCore
import SwiftUI

typealias KubeContextEditorMode = ProfileEditorMode

struct AddKubeContextView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) var dismiss
    let mode: KubeContextEditorMode
    let targetFolder: CloudFolder?
    let origin: ProfilePresentationSurface

    @State var selectedFolder: CloudFolder?
    @State var name = ""
    @State var server = ""
    @State var cluster = ""
    @State var user = ""
    @State var namespace = ""
    @State var token = ""
    @State var skipTLSVerification = false
    @State var isReplacingBearerToken = false
    @State var authMode: KubeContextAuthMode = .proxyTunnel
    @State var awsRegion = "us-east-1"
    @State var awsProfile = ""
    @State var isResolvingServer = false
    @State var isSaving = false
    @State var errorMessage = ""
    @State var resolveTask: Task<Void, Never>?
    @State var saveTask: Task<Void, Never>?

    init(
        store: ProfileStore,
        mode: KubeContextEditorMode = .create,
        targetFolder: CloudFolder? = nil,
        origin: ProfilePresentationSurface = .mainWindow
    ) {
        self.store = store
        self.mode = mode
        self.targetFolder = targetFolder
        self.origin = origin
        let kubeFolders = store.folders(for: .kubernetes)
        self._selectedFolder = State(initialValue: targetFolder ?? kubeFolders.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title(noun: "Kubernetes Context"))
                    .font(.title2.weight(.semibold))
                Text("Configure a context in ~/.kube/config.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Form {
                AddKubeContextDetailsSections(
                    store: store,
                    selectedFolder: $selectedFolder,
                    name: $name,
                    namespace: $namespace,
                    server: $server,
                    cluster: $cluster,
                    isResolvingServer: isResolvingServer,
                    isDuplicating: isDuplicating
                )

                AddKubeContextAuthSection(
                    authMode: $authMode,
                    user: $user,
                    awsRegion: $awsRegion,
                    awsProfile: $awsProfile,
                    isReplacingBearerToken: $isReplacingBearerToken,
                    token: $token,
                    awsProfiles: awsProfiles,
                    isDuplicating: isDuplicating,
                    hasExistingCredential: hasExistingCredential,
                    showsBearerTokenField: showsBearerTokenField,
                    isEditing: isEditing
                )

                if !isDuplicating {
                    Section("Transport Security") {
                        Toggle("Skip TLS certificate verification", isOn: $skipTLSVerification)
                        Text("Use only when the endpoint certificate cannot be verified.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 320, idealHeight: 420, maxHeight: 520)

            ProfileEditorErrorBanner(message: errorMessage)

            ProfileEditorFooter(
                actionTitle: mode.actionTitle,
                isBusy: isSaving,
                isConfirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty
                    || (!isDuplicating && server.trimmingCharacters(in: .whitespaces).isEmpty),
                cancel: { dismiss() },
                confirm: { save() }
            )
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            setupInitialValues()
        }
        .onDisappear {
            resolveTask?.cancel()
            saveTask?.cancel()
        }
        .onChange(of: name) { _, newName in
            autoDetectAuthMode(from: newName)
        }
        .onChange(of: cluster) { _, newCluster in
            autoDetectAuthMode(from: newCluster)
        }
        .onChange(of: server) { _, newServer in
            autoDetectAuthMode(from: newServer)
            if authMode == .cloudIAM, awsRegion.isEmpty {
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
}
