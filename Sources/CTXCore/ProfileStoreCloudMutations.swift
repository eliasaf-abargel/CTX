import Foundation


extension ProfileStore {
    public func addAWSProfile(
        _ draft: AWSProfileDraft,
        targetFolder: CloudFolder? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) throws {
        try add(provider: .aws, name: draft.name, targetFolder: targetFolder, origin: origin) {
            try profilePersistence.addAWSProfile(draft)
        }
    }

    public func updateAWSProfile(_ profile: CloudProfile, draft: AWSProfileDraft, targetFolder: CloudFolder? = nil, from origin: ProfilePresentationSurface = .mainWindow) throws {
        try update(profile, newName: draft.name, targetFolder: targetFolder, origin: origin) {
            try profilePersistence.updateAWSProfile(originalName: profile.name, draft: draft)
        }
    }

    public func loadAvailableAWSRoles(for profile: CloudProfile) async {
        guard profile.provider == .aws else {
            availableAWSRoles[profile.id] = []
            return
        }
        let accountID = profile.accountID
        let ssoStartURL = profile.ssoStartURL
        let roles = await Task.detached {
            AWSConfigParser.discoverAvailableRoles(
                accountID: accountID,
                ssoStartURL: ssoStartURL
            )
        }.value
        availableAWSRoles[profile.id] = roles
    }

    public func updateAWSRole(
        for profile: CloudProfile,
        roleName: String,
        targetFolder: CloudFolder?,
        from origin: ProfilePresentationSurface
    ) -> String? {
        var draft = AWSProfileDraft(profile: profile)
        draft.roleName = roleName
        do {
            try updateAWSProfile(
                profile,
                draft: draft,
                targetFolder: targetFolder,
                from: origin
            )
            return nil
        } catch {
            return sanitizedLifecycleMessage(error.localizedDescription)
        }
    }

    public func deleteAWSProfile(_ profile: CloudProfile) throws {
        try delete(profile) {
            try profilePersistence.deleteAWSProfile(profile.name)
        }
    }

    public func addGCPProfile(_ draft: GCPProfileDraft, targetFolder: CloudFolder? = nil, from origin: ProfilePresentationSurface = .mainWindow) throws {
        try add(provider: .gcp, name: draft.name, targetFolder: targetFolder, origin: origin) {
            try profilePersistence.addGCPProfile(draft)
        }
    }

    public func updateGCPProfile(_ profile: CloudProfile, draft: GCPProfileDraft, targetFolder: CloudFolder? = nil, from origin: ProfilePresentationSurface = .mainWindow) throws {
        try update(profile, newName: draft.name, targetFolder: targetFolder, origin: origin) {
            try profilePersistence.updateGCPProfile(originalName: profile.name, draft: draft)
        }
    }

    public func deleteGCPProfile(_ profile: CloudProfile) throws {
        try delete(profile) {
            try profilePersistence.deleteGCPProfile(profile.name)
        }
    }

    public func addAzureProfile(_ draft: AzureProfileDraft, targetFolder: CloudFolder? = nil, from origin: ProfilePresentationSurface = .mainWindow) throws {
        try add(provider: .azure, name: draft.name, targetFolder: targetFolder, origin: origin) {
            try profilePersistence.addAzureProfile(draft)
        }
    }

    public func updateAzureProfile(_ profile: CloudProfile, draft: AzureProfileDraft, targetFolder: CloudFolder? = nil, from origin: ProfilePresentationSurface = .mainWindow) throws {
        try update(profile, newName: draft.name, targetFolder: targetFolder, origin: origin) {
            try profilePersistence.updateAzureProfile(originalName: profile.name, draft: draft)
        }
    }

    public func deleteAzureProfile(_ profile: CloudProfile) throws {
        try delete(profile) {
            try profilePersistence.deleteAzureProfile(profile.name)
        }
    }

    internal func add(
        provider: CloudProvider,
        name: String,
        targetFolder: CloudFolder?,
        origin: ProfilePresentationSurface,
        persist: () throws -> Void
    ) rethrows {
        try persist()
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assignFolder(targetFolder, provider: provider, profileName: profileName)
        refreshImmediately()
        guard let profile = profiles.first(where: { $0.provider == provider && $0.name == profileName }) else { return }
        setActive(profile, from: origin)
        promptForFolderIfUnassigned(profile, targetFolder: targetFolder, from: origin)
    }

    internal func update(
        _ profile: CloudProfile,
        newName: String,
        targetFolder: CloudFolder?,
        origin: ProfilePresentationSurface,
        persist: () throws -> Void
    ) throws {
        let normalizedName = normalizeProfileName(newName)
        let previousFolderID = folderOverrides[profile.id]
        let targetFolderID = targetFolder?.provider == profile.provider ? targetFolder?.id : previousFolderID

        try persist()
        refreshImmediately()
        guard let updated = profiles.first(where: { $0.provider == profile.provider && $0.name == normalizedName }) else {
            throw ProfileStoreMutationError.rediscoveryMiss(provider: profile.provider, name: normalizedName)
        }
        migrateFolderOverride(from: profile.id, to: updated.id, folderID: targetFolderID)
        setActive(updated, from: origin)
    }

    internal func delete(_ profile: CloudProfile, persist: () throws -> Void) rethrows {
        try persist()
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        clearManualDisconnect(profile.id)
        if isActive(profile) {
            clearActive(for: profile.provider)
        }
        refreshImmediately()
        lastMessage = "Deleted \(profile.name)"
    }

    internal func normalizeProfileName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal func migrateFolderOverride(from oldProfileID: String, to newProfileID: String, folderID: String?) {
        migrateManualDisconnect(from: oldProfileID, to: newProfileID)
        if let folderID {
            folderOverrides[newProfileID] = folderID
            saveFolderOverrides()
        }
        guard oldProfileID != newProfileID else { return }
        folderOverrides.removeValue(forKey: oldProfileID)
        saveFolderOverrides()
    }
}
