import Combine
import Foundation

extension ProfileStore {
    internal func startAllFileWatchers() {
        fileWatchers.start(
            kubeConfigPath: kubeConfigDiscoveryService.candidatePaths().first?.path,
            awsConfigPath: AWSConfigPaths.configURL.path,
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
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    guard !self.gcpManuallyClearedByUser else { return }
                    let activeGCPName = GCPConfigParser.parseActiveConfig()
                    if !activeGCPName.isEmpty && activeGCPName != self.activeGCPProfile {
                        self.activeGCPProfile = activeGCPName
                        UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
                    }
                    self.verifyAllProfiles()
                }
            }
        )
    }

    public func refresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let discovered = await Task.detached {
                self.localProfileDiscovery.discover()
            }.value

            guard !Task.isCancelled else { return }

            self.apply(discovered, runVerification: true)
        }
    }

    internal func refreshImmediately(runVerification: Bool = true) {
        refreshDebounceTask?.cancel()
        let discovered = localProfileDiscovery.discover()
        apply(discovered, runVerification: runVerification)
    }

    internal func apply(_ discovered: LocalProfileDiscoveryResult, runVerification: Bool) {
        if kubernetesContexts != discovered.kubernetesContexts {
            kubernetesContexts = discovered.kubernetesContexts
        }
        if activeKubeContext != discovered.currentKubeContext {
            activeKubeContext = discovered.currentKubeContext
            UserDefaults.standard.set(discovered.currentKubeContext, forKey: "activeKubeContext")
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

        if !gcpManuallyClearedByUser {
            let activeGCPName = discovered.activeGCPProfile
            let currentIsConnected = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPProfile })?.status == .connected
            let discoveredIsConnected = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPName })?.status == .connected
            if activeGCPProfile != activeGCPName && (!currentIsConnected || discoveredIsConnected == true) {
                activeGCPProfile = activeGCPName
                UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
            } else if activeGCPProfile.isEmpty || (!currentIsConnected && discoveredIsConnected != true) {
                if let connectedGCP = profiles.first(where: { $0.provider == .gcp && $0.status == .connected }) {
                    activeGCPProfile = connectedGCP.name
                    UserDefaults.standard.set(connectedGCP.name, forKey: "activeGCPProfile")
                }
            }
        }

        if let selection = selectedSelection, case .profile(let pId) = selection, !profiles.contains(where: { $0.id == pId }) {
            selectedSelection = nil
        }

        var countsByProvider: [CloudProvider: Int] = [:]
        for profile in profiles {
            countsByProvider[profile.provider, default: 0] += 1
        }
        lastMessage = "Loaded \(countsByProvider[.aws] ?? 0) AWS profiles, \(countsByProvider[.gcp] ?? 0) GCP configurations and \(countsByProvider[.kubernetes] ?? 0) Kubernetes contexts"
        if runVerification {
            verifyAllProfiles()
        }
    }

    internal func kubeconfigPath(for contextName: String) -> String? {
        kubernetesContexts.first { $0.contextName == contextName }?.kubeconfigPath
            ?? kubeConfigDiscoveryService.candidatePaths().first?.path
    }

    public func addAWSProfile(_ draft: AWSProfileDraft, targetFolder: CloudFolder? = nil) throws {
        try add(provider: .aws, name: draft.name, targetFolder: targetFolder) {
            try profilePersistence.addAWSProfile(draft)
        }
    }

    public func updateAWSProfile(_ profile: CloudProfile, draft: AWSProfileDraft) throws {
        try update(profile, newName: draft.name) {
            try profilePersistence.updateAWSProfile(originalName: profile.name, draft: draft)
        }
    }

    public func deleteAWSProfile(_ profile: CloudProfile) throws {
        try delete(profile) {
            try profilePersistence.deleteAWSProfile(profile.name)
        }
    }

    public func addGCPProfile(_ draft: GCPProfileDraft, targetFolder: CloudFolder? = nil) throws {
        try add(provider: .gcp, name: draft.name, targetFolder: targetFolder) {
            try profilePersistence.addGCPProfile(draft)
        }
    }

    public func updateGCPProfile(_ profile: CloudProfile, draft: GCPProfileDraft) throws {
        try update(profile, newName: draft.name) {
            try profilePersistence.updateGCPProfile(originalName: profile.name, draft: draft)
        }
    }

    public func deleteGCPProfile(_ profile: CloudProfile) throws {
        try delete(profile) {
            try profilePersistence.deleteGCPProfile(profile.name)
        }
    }

    public func addAzureProfile(_ draft: AzureProfileDraft, targetFolder: CloudFolder? = nil) throws {
        try add(provider: .azure, name: draft.name, targetFolder: targetFolder) {
            try profilePersistence.addAzureProfile(draft)
        }
    }

    public func updateAzureProfile(_ profile: CloudProfile, draft: AzureProfileDraft) throws {
        try update(profile, newName: draft.name) {
            try profilePersistence.updateAzureProfile(originalName: profile.name, draft: draft)
        }
    }

    public func deleteAzureProfile(_ profile: CloudProfile) throws {
        try delete(profile) {
            try profilePersistence.deleteAzureProfile(profile.name)
        }
    }

    private func add(
        provider: CloudProvider,
        name: String,
        targetFolder: CloudFolder?,
        persist: () throws -> Void
    ) rethrows {
        try persist()
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assignFolder(targetFolder, provider: provider, profileName: profileName)
        refreshImmediately()
        guard let profile = profiles.first(where: { $0.provider == provider && $0.name == profileName }) else { return }
        setActive(profile)
        promptForFolderIfUnassigned(profile, targetFolder: targetFolder)
    }

    private func update(_ profile: CloudProfile, newName: String, persist: () throws -> Void) rethrows {
        try persist()
        let previousFolderID = folderOverrides.removeValue(forKey: profile.id)
        refreshImmediately()
        guard let updated = profiles.first(where: { $0.provider == profile.provider && $0.name == newName }) else { return }
        if let previousFolderID {
            folderOverrides[updated.id] = previousFolderID
            saveFolderOverrides()
        }
        setActive(updated)
    }

    private func delete(_ profile: CloudProfile, persist: () throws -> Void) rethrows {
        try persist()
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if isActive(profile) {
            clearActive(for: profile.provider)
        }
        refreshImmediately()
        lastMessage = "Deleted \(profile.name)"
    }

    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?,
        targetFolder: CloudFolder? = nil
    ) async throws {
        try await addKubeContext(
            name: name,
            server: server,
            cluster: cluster,
            user: user,
            namespace: namespace,
            credential: .bearerToken(token),
            targetFolder: targetFolder
        )
    }

    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        credential: KubeConfigCredential,
        targetFolder: CloudFolder? = nil
    ) async throws {
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await kubeConfigMutations.addContext(
            name: profileName,
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            cluster: cluster.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
            credential: credential,
            kubeconfigPath: kubeConfigDiscoveryService.candidatePaths().first?.path
        )
        if let targetFolder, targetFolder.provider == .kubernetes {
            folderOverrides[CloudProfile(provider: .kubernetes, name: profileName).id] = targetFolder.id
            saveFolderOverrides()
        }
        refreshImmediately()
        if let profile = profiles.first(where: { $0.provider == .kubernetes && $0.name == profileName }) {
            setActive(profile)
            promptForFolderIfUnassigned(profile, targetFolder: targetFolder)
        }
    }

    public func updateKubeContext(
        _ profile: CloudProfile,
        newName: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?
    ) async throws {
        let oldName = profile.name
        try await kubeConfigMutations.updateContext(oldName: oldName, newName: newName, server: server, cluster: cluster, user: user, namespace: namespace, token: token, kubeconfigPath: kubeconfigPath(for: oldName))

        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refreshImmediately()

        if let updated = profiles.first(where: { $0.provider == .kubernetes && $0.name == newName }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteKubeContext(_ profile: CloudProfile) async throws {
        let cacheContextID = kubernetesContexts.first { $0.contextName == profile.name }?.id

        try await kubeConfigMutations.deleteContext(profile.name, kubeconfigPath: kubeconfigPath(for: profile.name))

        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()

        if activeKubeContext == profile.name {
            clearActive(for: .kubernetes)
        }
        refreshImmediately()
        lastMessage = "Deleted context \(profile.name)"

        if let cacheContextID {
            Task.detached {
                await SQLiteResourceCache().clearContext(cacheContextID)
            }
        }
    }

    public func resolveKubeServer(for clusterName: String, contextName: String? = nil) async -> String {
        let path = contextName.flatMap(kubeconfigPath(for:)) ?? kubeConfigDiscoveryService.candidatePaths().first?.path
        return await kubeConfigMutations.resolveServer(for: clusterName, kubeconfigPath: path)
    }

    internal func fetchAndStoreCredentials(for profile: CloudProfile) async {
        lastMessage = "Fetching STS credentials for \(profile.name)..."
        let result = await profileCommands.exportAWSCredentials(for: profile)
        if result.exitCode == 0 {
            do {
                let stored = try awsCredentials.storeExportedCredentials(
                    result.output,
                    profileName: profile.name,
                    isActiveProfile: profile.name == activeAWSProfile
                )
                if profile.name == activeAWSProfile {
                    activeAWSExpiresAt = stored.expiresAt
                }
                lastMessage = "STS credentials retrieved & stored in ~/.aws/credentials"
            } catch {
                lastMessage = "Failed to write STS credentials: \(error.localizedDescription)"
            }
        } else {
            lastMessage = "Failed to fetch STS credentials: \(result.output)"
        }
    }
}
