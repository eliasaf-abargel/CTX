import Foundation

extension ProfileStore {
    internal func runLogout(
        _ profile: CloudProfile,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async {
        guard !Task.isCancelled,
              isCurrentOperation(profileID: profile.id, operationID: operationID) else {
            return
        }
        let previousStatus = profiles.first(where: { $0.id == profile.id })?.status ?? profile.status
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
        guard result.exitCode == 0 else {
            clearManualDisconnect(profile.id)
            updateStatus(profile, status: previousStatus, operationID: operationID)
            report(result.output, title: "Disconnect Failed", from: origin)
            return
        }
        if isActive(profile) {
            clearActive(
                for: profile.provider,
                cancellingOperations: false,
                kubeOwnerProfileID: profile.provider == .kubernetes ? profile.id : nil
            )
        }
        updateStatus(profile, status: .needsLogin, operationID: operationID)
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
