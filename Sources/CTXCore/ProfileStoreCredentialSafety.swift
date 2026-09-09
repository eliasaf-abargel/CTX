import Foundation

extension ProfileStore {
    public func canExportAWSCredentials(_ profile: CloudProfile) -> Bool {
        guard profile.provider == .aws,
              activeAWSProfile == profile.name,
              profiles.first(where: { $0.id == profile.id })?.status == .connected else {
            return false
        }
        return !hasProfileOperation(for: .aws)
    }

    public func exportAWSCredentials(
        _ profile: CloudProfile,
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        guard canExportAWSCredentials(profile) else { return }
        _ = startProfileOperation(
            for: profile,
            kind: .exportCredentials,
            origin: origin
        ) { @MainActor [weak self] operationID in
            guard let self else { return }
            _ = await self.performAWSCredentialExport(
                for: profile,
                operationID: operationID,
                origin: origin
            )
        }
    }

    internal func performAWSCredentialExport(
        for profile: CloudProfile,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async -> Bool {
        guard profile.provider == .aws,
              isCurrentOperation(profileID: profile.id, operationID: operationID),
              activeAWSProfile == profile.name,
              profiles.first(where: { $0.id == profile.id })?.status == .connected else {
            if isCurrentOperation(profileID: profile.id, operationID: operationID) {
                report(
                    "Activate \(profile.name) before exporting credentials.",
                    title: "Credential Export Unavailable",
                    from: origin
                )
            }
            return false
        }

        lastMessage = "Exporting temporary AWS credentials for \(profile.name)..."
        let result = await profileCommands.exportAWSCredentials(for: profile)
        guard !Task.isCancelled,
              isCurrentOperation(profileID: profile.id, operationID: operationID),
              activeAWSProfile == profile.name,
              profiles.first(where: { $0.id == profile.id })?.status == .connected else {
            return false
        }
        guard result.exitCode == 0 else {
            report(result.output, title: "Credential Export Failed", from: origin)
            return false
        }
        do {
            let stored = try awsCredentials.storeExportedCredentials(
                result.output,
                profileName: profile.name
            )
            activeAWSExpiresAt = stored.expiresAt
            lastMessage = "Exported credentials for \(profile.name)"
            return true
        } catch {
            report(
                "Failed to write exported credentials: \(error.localizedDescription)",
                title: "Credential Export Failed",
                from: origin
            )
            return false
        }
    }

    internal func beginProviderSignOut(
        _ profile: CloudProfile,
        from origin: ProfilePresentationSurface
    ) {
        _ = startProfileOperation(
            for: profile,
            kind: .providerSignOut,
            origin: origin
        ) { @MainActor [weak self] operationID in
            guard let self else { return }
            await self.runProviderSignOut(
                profile,
                operationID: operationID,
                origin: origin
            )
        }
    }

    private func runProviderSignOut(
        _ profile: CloudProfile,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async {
        guard profile.provider != .kubernetes,
              isCurrentOperation(profileID: profile.id, operationID: operationID) else {
            return
        }
        let previousStatus = profiles.first(where: { $0.id == profile.id })?.status
            ?? profile.status
        updateStatus(profile, status: .disconnecting, operationID: operationID)
        lastMessage = "Signing out from \(profile.provider.rawValue)..."
        let result = await profileCommands.signOutFromProvider(profile)
        guard !Task.isCancelled,
              isCurrentOperation(profileID: profile.id, operationID: operationID) else {
            return
        }
        guard result.exitCode == 0 else {
            updateStatus(profile, status: previousStatus, operationID: operationID)
            report(result.output, title: "Provider Sign-Out Failed", from: origin)
            return
        }

        cancelProviderOperations(
            for: profile.provider,
            excludingProfileID: profile.id,
            operationID: operationID
        )
        let matchingProfiles = profiles.filter {
            providerSignOutAffects($0, requestedProfile: profile)
        }
        if profile.provider == .aws {
            do {
                try awsCredentials.clearExportedTemporaryCredentials()
            } catch {
                report(
                    "AWS signed out, but CTX could not remove exported temporary credentials: \(error.localizedDescription)",
                    title: "Credential Cleanup Failed",
                    from: origin
                )
            }
        }
        markManuallyDisconnected(matchingProfiles.map(\.id))
        if providerSignOutClearsActiveProfile(
            provider: profile.provider,
            matchingProfiles: matchingProfiles
        ) {
            clearActive(
                for: profile.provider,
                cancellingOperations: false,
                kubeOwnerProfileID: nil
            )
        }
        for matchingProfile in matchingProfiles {
            updateStatus(
                matchingProfile,
                status: .needsLogin,
                operationID: matchingProfile.id == profile.id ? operationID : nil
            )
        }
        lastMessage = "Signed out from \(profile.provider.rawValue)"
        refresh()
    }

    private func providerSignOutAffects(
        _ candidate: CloudProfile,
        requestedProfile: CloudProfile
    ) -> Bool {
        guard candidate.provider == requestedProfile.provider else { return false }
        switch requestedProfile.provider {
        case .aws, .azure:
            return true
        case .gcp:
            return gcpAccount(for: candidate) == gcpAccount(for: requestedProfile)
        case .kubernetes:
            return false
        }
    }

    private func gcpAccount(for profile: CloudProfile) -> String? {
        [profile.roleName, profile.accountID]
            .first { $0.contains("@") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func providerSignOutClearsActiveProfile(
        provider: CloudProvider,
        matchingProfiles: [CloudProfile]
    ) -> Bool {
        switch provider {
        case .aws, .azure:
            return true
        case .gcp:
            return matchingProfiles.contains { $0.name == activeGCPProfile }
        case .kubernetes:
            return false
        }
    }
}
