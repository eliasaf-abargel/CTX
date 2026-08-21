import Foundation

extension ProfileStore {
    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?,
        skipTLSVerification: Bool = false,
        targetFolder: CloudFolder? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) async throws {
        try await addKubeContext(
            name: name,
            server: server,
            cluster: cluster,
            user: user,
            namespace: namespace,
            credential: .bearerToken(token),
            skipTLSVerification: skipTLSVerification,
            targetFolder: targetFolder,
            from: origin
        )
    }

    public func suggestedKubeContextDuplicateName(for profile: CloudProfile) -> String {
        let sourceName = normalizeProfileName(profile.name)
        let baseName = "\(sourceName)-copy"
        let existingNames = Set(profiles.lazy.filter { $0.provider == .kubernetes }.map(\.name))
        guard existingNames.contains(baseName) else { return baseName }

        var suffix = 2
        while existingNames.contains("\(baseName)-\(suffix)") {
            suffix += 1
        }
        return "\(baseName)-\(suffix)"
    }

    public func duplicateKubeContext(
        _ source: CloudProfile,
        newName: String,
        targetFolder: CloudFolder? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) async throws {
        let profileName = normalizeProfileName(newName)
        guard !profiles.contains(where: { $0.provider == .kubernetes && $0.name == profileName }) else {
            throw KubeConfigMutationError.invalid("A Kubernetes context named “\(profileName)” already exists")
        }
        guard let sourceContext = kubernetesContexts.first(where: { $0.contextName == source.name }) else {
            throw KubeConfigMutationError.invalid("Source Kubernetes context was not found")
        }

        try await kubeConfigMutations.duplicateContext(
            sourceName: sourceContext.contextName,
            newName: profileName,
            cluster: sourceContext.clusterName,
            user: sourceContext.userName,
            namespace: sourceContext.namespace,
            kubeconfigPath: sourceContext.kubeconfigPath
        )

        let inheritedFolder: CloudFolder = if let targetFolder, targetFolder.provider == .kubernetes {
            targetFolder
        } else {
            folder(for: source)
        }
        refreshImmediately()

        guard let duplicate = profiles.first(where: { $0.provider == .kubernetes && $0.name == profileName }) else {
            throw ProfileStoreMutationError.rediscoveryMiss(provider: .kubernetes, name: profileName)
        }
        folderOverrides[duplicate.id] = inheritedFolder.id
        saveFolderOverrides()
        setActive(duplicate, from: origin)
    }

    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        credential: KubeConfigCredential,
        skipTLSVerification: Bool = false,
        targetFolder: CloudFolder? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) async throws {
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await kubeConfigMutations.addContext(
            name: profileName,
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            cluster: cluster.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
            credential: credential,
            skipTLSVerification: skipTLSVerification,
            kubeconfigPath: kubeConfigDiscoveryService.candidatePaths().first?.path
        )
        if let targetFolder, targetFolder.provider == .kubernetes {
            folderOverrides[CloudProfile(provider: .kubernetes, name: profileName).id] = targetFolder.id
            saveFolderOverrides()
        }
        refreshImmediately()
        if let profile = profiles.first(where: { $0.provider == .kubernetes && $0.name == profileName }) {
            setActive(profile, from: origin)
            promptForFolderIfUnassigned(profile, targetFolder: targetFolder, from: origin)
        }
    }

    public func updateKubeContext(
        _ profile: CloudProfile,
        newName: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?,
        skipTLSVerification: Bool? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) async throws {
        let credentialUpdate: KubeConfigCredentialUpdate = if let token, !token.isEmpty {
            .replace(.bearerToken(token))
        } else {
            .preserveExisting
        }
        try await updateKubeContext(
            profile,
            newName: newName,
            server: server,
            cluster: cluster,
            user: user,
            namespace: namespace,
            credentialUpdate: credentialUpdate,
            skipTLSVerification: skipTLSVerification,
            from: origin
        )
    }

    public func updateKubeContext(
        _ profile: CloudProfile,
        newName: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        credentialUpdate: KubeConfigCredentialUpdate,
        skipTLSVerification: Bool? = nil,
        targetFolder: CloudFolder? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) async throws {
        let oldName = profile.name
        let normalizedName = normalizeProfileName(newName)
        let previousFolderID = folderOverrides[profile.id]
        let targetFolderID = targetFolder?.provider == .kubernetes ? targetFolder?.id : previousFolderID
        try await kubeConfigMutations.updateContext(
            oldName: oldName,
            newName: normalizedName,
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            cluster: cluster.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialUpdate: credentialUpdate,
            skipTLSVerification: skipTLSVerification,
            kubeconfigPath: kubeconfigPath(for: oldName)
        )

        refreshImmediately()

        guard let updated = profiles.first(where: { $0.provider == .kubernetes && $0.name == normalizedName }) else {
            throw ProfileStoreMutationError.rediscoveryMiss(provider: .kubernetes, name: normalizedName)
        }
        migrateFolderOverride(from: profile.id, to: updated.id, folderID: targetFolderID)
        setActive(updated, from: origin)
    }

    public func deleteKubeContext(_ profile: CloudProfile) async throws {
        let cacheContextID = kubernetesContexts.first { $0.contextName == profile.name }?.id

        try await kubeConfigMutations.deleteContext(profile.name, kubeconfigPath: kubeconfigPath(for: profile.name))

        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        clearManualDisconnect(profile.id)

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
}
