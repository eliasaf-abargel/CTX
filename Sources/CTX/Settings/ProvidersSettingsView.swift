import CTXCore
import SwiftUI

struct ProvidersSettingsView: View {
    @ObservedObject var store: ProfileStore

    @AppStorage(CTXDefaultsKey.awsConfigPath) private var awsConfigPath = ""
    @AppStorage(CTXDefaultsKey.awsCredentialsPath) private var awsCredentialsPath = ""
    @AppStorage(CTXDefaultsKey.gcpConfigDirPath) private var gcpConfigDirPath = ""
    @AppStorage(CTXDefaultsKey.azureProfilesDirPath) private var azureProfilesDirPath = ""
    @AppStorage(CTXDefaultsKey.azureCLIDirPath) private var azureCLIDirPath = ""
    @AppStorage(CTXDefaultsKey.kubeconfigPath) private var kubeconfigPath = ""

    var body: some View {
        Form {
            Section {
                ConfigPathRow(
                    title: "Config",
                    defaultPath: home(".aws", "config"),
                    selects: .file,
                    path: $awsConfigPath
                )
                ConfigPathRow(
                    title: "Credentials",
                    defaultPath: home(".aws", "credentials"),
                    selects: .file,
                    path: $awsCredentialsPath
                )
            } header: {
                providerHeader(.aws, "AWS", count(.aws), "profiles")
            }

            Section {
                ConfigPathRow(
                    title: "Configurations",
                    defaultPath: home(".config", "gcloud", "configurations"),
                    selects: .directory,
                    path: $gcpConfigDirPath
                )
            } header: {
                providerHeader(.gcp, "Google Cloud", count(.gcp), "configurations")
            }

            Section {
                ConfigPathRow(
                    title: "Profiles",
                    defaultPath: home(".config", "ctx", "azure"),
                    selects: .directory,
                    path: $azureProfilesDirPath
                )
                ConfigPathRow(
                    title: "CLI directory",
                    defaultPath: home(".azure"),
                    selects: .directory,
                    path: $azureCLIDirPath
                )
            } header: {
                providerHeader(.azure, "Azure", count(.azure), "subscriptions")
            }

            Section {
                ConfigPathRow(
                    title: "Kubeconfig",
                    defaultPath: home(".kube", "config"),
                    selects: .file,
                    path: $kubeconfigPath
                )
            } header: {
                providerHeader(.kubernetes, "Kubernetes", count(.kubernetes), "contexts")
            }

            Section {
                Menu {
                    Button("AWS Profile…") { store.triggerSheet = .addAWSProfile }
                    Button("Google Cloud Config…") { store.triggerSheet = .addGCPProfile }
                    Button("Azure Subscription…") { store.triggerSheet = .addAzureProfile }
                    Button("Kubernetes Context…") { store.triggerSheet = .addKubeContext }
                } label: {
                    Label("Connect another provider…", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The parsers read these keys on demand, so a changed path only reaches
        // the profile list once the store re-reads the files.
        .onChange(of: awsConfigPath) { _, _ in store.refresh() }
        .onChange(of: awsCredentialsPath) { _, _ in store.refresh() }
        .onChange(of: gcpConfigDirPath) { _, _ in store.refresh() }
        .onChange(of: azureProfilesDirPath) { _, _ in store.refresh() }
        .onChange(of: azureCLIDirPath) { _, _ in store.refresh() }
        .onChange(of: kubeconfigPath) { _, _ in store.refresh() }
    }

    private func providerHeader(
        _ provider: CloudProvider,
        _ title: String,
        _ count: Int,
        _ noun: String
    ) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 14)
            Text(title)
            Spacer()
            Text("\(count) \(noun)")
                .foregroundStyle(.secondary)
        }
    }

    private func count(_ provider: CloudProvider) -> Int {
        store.profiles.filter { $0.provider == provider }.count
    }

    private func home(_ components: String...) -> String {
        components
            .reduce(FileManager.default.homeDirectoryForCurrentUser) {
                $0.appendingPathComponent($1)
            }
            .path
    }
}
