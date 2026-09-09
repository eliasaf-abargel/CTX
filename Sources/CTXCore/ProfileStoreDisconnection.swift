import Foundation

extension ProfileStore {
    public func isManuallyDisconnected(_ profile: CloudProfile) -> Bool {
        manuallyDisconnectedProfiles.contains(profile.id)
    }

    public func needsDisconnectRetry(_ profile: CloudProfile) -> Bool {
        isManuallyDisconnected(profile) && verificationErrors[profile.id] != nil
    }

    internal func runLogout(
        _ profile: CloudProfile,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async {
        guard !Task.isCancelled,
              isCurrentOperation(profileID: profile.id, operationID: operationID) else {
            return
        }
        let started = Date()
        markManuallyDisconnected(profile.id)
        dismissLifecyclePresentation(for: profile.id, from: origin)
        updateStatus(profile, status: .disconnecting, operationID: operationID)

        let isBrokerScoped = profile.provider == .kubernetes && (profile.usesStrongDM || profile.usesTeleport)
        let result: CommandResult
        if isBrokerScoped {
            lastMessage = "Disconnecting \(profile.usesStrongDM ? "StrongDM" : "Teleport") resource \(profile.name)..."
            result = await profileCommands.logout(profile)
        } else {
            result = CommandResult(exitCode: 0, output: "")
        }

        guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
        logConnectCall(step: "app_disconnect", kind: profile.provider.rawValue, profileID: profile.id, started: started, outcome: result.exitCode == 0 ? "success" : "failure")
        if isActive(profile) {
            clearActive(
                for: profile.provider,
                cancellingOperations: false,
                kubeOwnerProfileID: profile.provider == .kubernetes ? profile.id : nil
            )
        }
        updateStatus(profile, status: .needsLogin, operationID: operationID)
        guard result.exitCode == 0 else {
            lastMessage = "CTX stopped using this profile. The broker disconnect could not be confirmed; retry Disconnect."
            verificationErrors[profile.id] = lastMessage
            return
        }
        verificationErrors[profile.id] = nil
        lastMessage = isBrokerScoped
            ? "Disconnected \(profile.name)"
            : "Disconnected \(profile.name) from CTX"
        refresh()
    }

    internal func markManuallyDisconnected(_ profileID: String) {
        guard manuallyDisconnectedProfiles.insert(profileID).inserted else { return }
        persistManualDisconnects()
    }

    internal func markManuallyDisconnected<S: Sequence>(_ profileIDs: S) where S.Element == String {
        let previousCount = manuallyDisconnectedProfiles.count
        manuallyDisconnectedProfiles.formUnion(profileIDs)
        guard manuallyDisconnectedProfiles.count != previousCount else { return }
        persistManualDisconnects()
    }

    internal func clearManualDisconnect(_ profileID: String) {
        guard manuallyDisconnectedProfiles.remove(profileID) != nil else { return }
        persistManualDisconnects()
    }

    internal func migrateManualDisconnect(from oldProfileID: String, to newProfileID: String) {
        guard oldProfileID != newProfileID,
              manuallyDisconnectedProfiles.remove(oldProfileID) != nil else {
            return
        }
        manuallyDisconnectedProfiles.insert(newProfileID)
        persistManualDisconnects()
    }

    private func persistManualDisconnects() {
        defaults.set(
            manuallyDisconnectedProfiles.sorted(),
            forKey: CTXDefaultsKey.manuallyDisconnectedProfileIDs
        )
    }
}
