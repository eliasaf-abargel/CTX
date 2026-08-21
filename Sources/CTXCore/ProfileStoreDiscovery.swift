import Foundation

public enum ProfileStoreMutationError: LocalizedError, Equatable, Sendable {
    case rediscoveryMiss(provider: CloudProvider, name: String)

    public var errorDescription: String? {
        switch self {
        case .rediscoveryMiss(let provider, let name):
            "\(provider.rawValue) profile “\(name)” was not found after saving"
        }
    }
}

extension ProfileStore {
    internal func startAllFileWatchers() {
        fileWatchers.start(
            kubeConfigPath: kubeConfigDiscoveryService.candidatePaths().first?.path,
            awsConfigPath: Self.configuredURL(
                defaultsKey: CTXDefaultsKey.awsConfigPath,
                fallback: configURL,
                defaults: defaults
            ).path,
            gcpActiveConfigPath: GCPConfigPaths.activeConfigURL.path,
            gcpConfigsDirPath: GCPConfigPaths.configurationsDirURL.path,
            azureProfilesDirPath: AzureConfigPaths.profilesDirURL.path,
            onRefresh: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            },
            onGCPActiveConfigChanged: { [weak self] in
                guard let self else { return }
                self.gcpActiveConfigDebounceTask?.cancel()
                self.gcpActiveConfigDebounceTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: 300_000_000)
                    } catch {
                        return
                    }
                    guard !self.hasProfileOperation(for: .gcp) else {
                        return
                    }
                    self.verifyAllProfiles()
                }
            }
        )
    }

    /// Re-reads configured provider sources and safely rebinds file watchers.
    public func reloadConfiguredSources() {
        if backgroundServicesEnabled {
            startAllFileWatchers()
        }
        refresh()
    }

    public func refresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }

            let discovered = await Task.detached {
                self.localProfileDiscovery.discover()
            }.value

            guard !Task.isCancelled else { return }

            self.apply(discovered, runVerification: true)
        }
    }

    public func refreshImmediately(runVerification: Bool = true) {
        refreshDebounceTask?.cancel()
        let discovered = localProfileDiscovery.discover()
        apply(discovered, runVerification: runVerification)
    }

    internal func apply(_ discovered: LocalProfileDiscoveryResult, runVerification: Bool) {
        if kubernetesContexts != discovered.kubernetesContexts {
            kubernetesContexts = discovered.kubernetesContexts
        }

        let statusByID = Dictionary(profiles.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        var mergedProfiles = discovered.profiles
        for index in mergedProfiles.indices {
            if let status = statusByID[mergedProfiles[index].id] {
                mergedProfiles[index].status = status
            }
        }
        if profiles != mergedProfiles {
            profiles = mergedProfiles
        }
        let discoveredProfileIDs = Set(mergedProfiles.map(\.id))
        cancelOperationsForMissingProfiles(discoveredProfileIDs)
        applyDiscoveredKubeContext(
            discovered.currentKubeContext,
            currentContextByPath: discovered.currentKubeContextByPath
        )

        if let selection = selectedSelection, case .profile(let pId) = selection, !profiles.contains(where: { $0.id == pId }) {
            selectedSelection = nil
        }

        var countsByProvider: [CloudProvider: Int] = [:]
        for profile in profiles {
            countsByProvider[profile.provider, default: 0] += 1
        }
        if profileOperations.isEmpty && lastMessage.isEmpty {
            lastMessage = "Loaded \(countsByProvider[.aws] ?? 0) AWS profiles, \(countsByProvider[.gcp] ?? 0) GCP configurations and \(countsByProvider[.kubernetes] ?? 0) Kubernetes contexts"
        }
        if runVerification {
            verifyAllProfiles()
        }
    }

    internal func kubeconfigPath(for contextName: String) -> String? {
        kubernetesContexts.first { $0.contextName == contextName }?.kubeconfigPath
            ?? kubeConfigDiscoveryService.candidatePaths().first?.path
    }
}
