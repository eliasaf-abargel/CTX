import Foundation

extension ProfileStore {
    internal func pollForConnectedProfile(
        _ profile: CloudProfile,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async {
        let requiresPolling = profile.provider == .kubernetes && (profile.usesStrongDM || profile.usesTeleport)
        let attempts = requiresPolling ? 8 : 1
        for attempt in 0..<attempts {
            guard !Task.isCancelled,
                  isCurrentOperation(profileID: profile.id, operationID: operationID) else {
                return
            }
            if await verify(profile, isManualAttempt: attempt == attempts - 1, operationID: operationID) {
                guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
                if profile.provider == .aws {
                    _ = await performAWSCredentialExport(
                        for: profile,
                        operationID: operationID,
                        origin: origin
                    )
                    guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
                }
                dismissInAppAuth(profileID: profile.id, operationID: operationID, origin: origin)
                return
            }
            guard attempt < attempts - 1 else { return }
            updateStatus(profile, status: .connecting, operationID: operationID)
            do {
                try await brokerPollDelay()
                try Task.checkCancellation()
            } catch {
                return
            }
        }
    }
}
