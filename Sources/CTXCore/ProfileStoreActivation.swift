import Foundation

extension ProfileStore {
    /// The selected name for a provider, whether or not it is connected.
    public func activeProfileName(for provider: CloudProvider) -> String {
        switch provider {
        case .aws: activeAWSProfile
        case .gcp: activeGCPProfile
        case .azure: activeAzureProfile
        case .kubernetes: activeKubeContext
        }
    }

    public func activeProfile(for provider: CloudProvider) -> CloudProfile? {
        let name = activeProfileName(for: provider)

        guard !name.isEmpty,
              let profile = profiles.first(where: { $0.provider == provider && $0.name == name }),
              profile.status == .connected else {
            return nil
        }
        return profile
    }

    public func isActive(_ profile: CloudProfile) -> Bool {
        if let active = activeProfile(for: profile.provider) {
            return active.id == profile.id
        }
        switch profile.provider {
        case .aws:
            return activeAWSProfile == profile.name
        case .gcp:
            return activeGCPProfile == profile.name
        case .azure:
            return activeAzureProfile == profile.name
        case .kubernetes:
            return activeKubeContext == profile.name
        }
    }

    public func setActive(
        _ profile: CloudProfile,
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        if profileOperations[profile.id]?.kind == .activate {
            return
        }
        let wasActive = isActive(profile)
        cancelActivationOperations(for: profile.provider, excluding: profile.id)
        cancelProfileOperation(profileID: profile.id)
        setActiveState(profile)
        _ = startProfileOperation(for: profile, kind: .activate, origin: origin) { @MainActor [weak self] operationID in
            guard let self else { return }
            await self.runProfileActivation(
                profile,
                wasActive: wasActive,
                operationID: operationID,
                origin: origin
            )
        }
    }

    internal func setActiveState(_ profile: CloudProfile, operationID: UUID? = nil) {
        guard canPublishLifecycleState(for: profile.id, operationID: operationID) else { return }
        if case .profile(let profileID) = selectedSelection, profileID == profile.id {
            // The profile is already selected.
        } else {
            selectedSelection = .profile(profile.id)
        }
        switch profile.provider {
        case .aws:
            if activeAWSProfile != profile.name {
                let previousProfileName = activeAWSProfile
                if !previousProfileName.isEmpty {
                    cancelSupersededAWSOperations(previousProfileName: previousProfileName)
                }
                activeAWSProfile = profile.name
                defaults.set(profile.name, forKey: "activeAWSProfile")
                // Not "AWS_PROFILE=…": a GUI cannot set an environment variable inside a
                // shell that is already running, and this never did. Selecting a profile
                // scopes what CTX itself does; a terminal is scoped when it is opened.
                lastMessage = "Active profile: \(profile.name)"
                recordShellSelection()
            }
        case .gcp:
            if activeGCPProfile != profile.name {
                activeGCPProfile = profile.name
                defaults.set(profile.name, forKey: "activeGCPProfile")
                lastMessage = "Active GCP configuration=\(profile.name)"
                recordShellSelection()
            }
        case .azure:
            if activeAzureProfile != profile.name {
                activeAzureProfile = profile.name
                defaults.set(profile.name, forKey: "activeAzureProfile")
                lastMessage = "Active Azure subscription=\(profile.name)"
            }
        case .kubernetes:
            break
        }
    }

    private func runProfileActivation(
        _ profile: CloudProfile,
        wasActive: Bool,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async {
        guard !Task.isCancelled,
              isCurrentOperation(profileID: profile.id, operationID: operationID) else {
            return
        }
        if wasActive && profile.status == .connected {
            if profile.provider == .aws {
                checkAllSessionsExpiration()
            }
            return
        }

        let startedAt = Date()
        switch profile.provider {
        case .aws:
            guard !Task.isCancelled,
                  isCurrentOperation(profileID: profile.id, operationID: operationID) else {
                return
            }
            checkAllSessionsExpiration()
            _ = await verify(profile, operationID: operationID)
        case .gcp:
            let result = await profileCommands.activateGCPConfiguration(profile)
            guard !Task.isCancelled,
                  isCurrentOperation(profileID: profile.id, operationID: operationID) else {
                return
            }
            lastCommandDuration = Date().timeIntervalSince(startedAt)
            if result.exitCode == 0 {
                lastMessage = "Activated GCP configuration \(profile.name)"
            } else {
                report(
                    "Failed to activate GCP configuration: \(result.output)",
                    title: "Activation Failed",
                    from: origin
                )
            }
            _ = await verify(profile, operationID: operationID)
        case .azure:
            let result = await profileCommands.activateAzureSubscription(profile)
            guard !Task.isCancelled,
                  isCurrentOperation(profileID: profile.id, operationID: operationID) else {
                return
            }
            lastCommandDuration = Date().timeIntervalSince(startedAt)
            if result.exitCode == 0 {
                lastMessage = "Activated Azure subscription \(profile.name)"
            } else {
                report(
                    "Failed to activate Azure subscription: \(result.output)",
                    title: "Activation Failed",
                    from: origin
                )
            }
            _ = await verify(profile, operationID: operationID)
        case .kubernetes:
            let targetKubeconfigPath = kubeconfigPath(for: profile.name)
                ?? kubeConfigDiscoveryService.candidatePaths().first?.path
                ?? ""
            let activationGeneration = beginKubeContextActivation(
                target: profile.name,
                kubeconfigPath: targetKubeconfigPath,
                ownerProfileID: profile.id,
                operationID: operationID
            )
            lastMessage = "Active kube context=\(profile.name)"
            let result = await kubeConfigMutations.useContext(
                profile.name,
                kubeconfigPath: targetKubeconfigPath
            )
            guard !Task.isCancelled,
                  isCurrentOperation(profileID: profile.id, operationID: operationID),
                  pendingKubeContextActivation?.generation == activationGeneration else {
                return
            }
            lastCommandDuration = Date().timeIntervalSince(startedAt)
            if result.exitCode == 0 {
                lastMessage = "Switched kube context to \(profile.name)"
            } else {
                report(
                    "Failed to switch context: \(result.output)",
                    title: "Context Switch Failed",
                    from: origin
                )
            }
            completeKubeContextActivation(generation: activationGeneration, result: result)
            refresh()
            verifyAllProfiles()
        }
    }

    public func clearActive(for provider: CloudProvider) {
        clearActive(for: provider, cancellingOperations: true, kubeOwnerProfileID: nil)
    }

    internal func clearActive(
        for provider: CloudProvider,
        cancellingOperations: Bool,
        kubeOwnerProfileID: String?
    ) {
        if cancellingOperations {
            for profile in profiles where profile.provider == provider {
                cancelProfileOperation(profileID: profile.id)
            }
        }
        switch provider {
        case .aws:
            activeAWSProfile = ""
            defaults.removeObject(forKey: "activeAWSProfile")
            awsIdentity = ""
            activeAWSExpiresAt = nil
            lastMessage = "No active AWS profile"
            try? awsCredentials.clearDefaultProfile()
            recordShellSelection()
        case .gcp:
            activeGCPProfile = ""
            defaults.removeObject(forKey: "activeGCPProfile")
            lastMessage = "No active GCP configuration"
        case .azure:
            activeAzureProfile = ""
            defaults.removeObject(forKey: "activeAzureProfile")
            lastMessage = "No active Azure subscription"
        case .kubernetes:
            if let kubeOwnerProfileID {
                cancelKubeContextActivation(ownerProfileID: kubeOwnerProfileID, revert: false)
            } else {
                pendingKubeContextActivation = nil
            }
            activeKubeContext = ""
            defaults.removeObject(forKey: "activeKubeContext")
            lastMessage = "No active kube context"
        }
        showExpirationWarning = false
    }

    public func clearActive() {
        clearActive(for: .aws)
    }
}
