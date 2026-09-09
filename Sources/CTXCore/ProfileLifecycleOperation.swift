import Foundation

internal enum ProfileLifecycleOperationKind: Sendable {
    case connect
    case disconnect
    case activate
    case exportCredentials
    case providerSignOut
}

internal struct ProfileLifecycleOperation {
    let id: UUID
    let kind: ProfileLifecycleOperationKind
    let origin: ProfilePresentationSurface
    let task: Task<Void, Never>
}

internal struct KubeContextActivationIntent: Equatable, Sendable {
    let generation: UUID
    let ownerProfileID: String
    let operationID: UUID
    let target: String
    let previous: String
    let kubeconfigPath: String
}

extension ProfileStore {
    @discardableResult
    internal func startProfileOperation(
        for profile: CloudProfile,
        kind: ProfileLifecycleOperationKind,
        origin: ProfilePresentationSurface,
        body: @escaping @MainActor (UUID) async -> Void
    ) -> UUID? {
        if let current = profileOperations[profile.id] {
            guard current.kind != kind else { return nil }
            cancelProfileOperation(profileID: profile.id)
        }

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await body(operationID)
            self?.finishProfileOperation(profileID: profile.id, operationID: operationID)
        }
        profileOperations[profile.id] = ProfileLifecycleOperation(
            id: operationID,
            kind: kind,
            origin: origin,
            task: task
        )
        return operationID
    }

    internal func isCurrentOperation(profileID: String, operationID: UUID) -> Bool {
        guard let operation = profileOperations[profileID] else { return false }
        return operation.id == operationID
    }

    internal func hasProfileOperation(profileID: String) -> Bool {
        profileOperations[profileID] != nil
    }

    internal func finishProfileOperation(profileID: String, operationID: UUID) {
        guard profileOperations[profileID]?.id == operationID else { return }
        profileOperations[profileID] = nil
    }

    internal func cancelOperationsForMissingProfiles(_ profileIDs: Set<String>) {
        let missingProfileIDs = profileOperations.keys.filter { !profileIDs.contains($0) }
        for profileID in missingProfileIDs {
            profileOperations[profileID]?.task.cancel()
            profileOperations[profileID] = nil
        }
        if let intent = pendingKubeContextActivation,
           !profileIDs.contains(intent.ownerProfileID) {
            cancelKubeContextActivation(
                ownerProfileID: intent.ownerProfileID,
                operationID: intent.operationID,
                revert: true
            )
        }
    }

    internal func cancelProfileOperation(
        profileID: String,
        revertKubeActivation: Bool = true
    ) {
        guard let operation = profileOperations[profileID] else { return }
        operation.task.cancel()
        cancelKubeContextActivation(
            ownerProfileID: profileID,
            operationID: operation.id,
            revert: revertKubeActivation
        )
        profileOperations[profileID] = nil
    }

    internal func cancelActivationOperations(for provider: CloudProvider, excluding profileID: String) {
        for profile in profiles where profile.provider == provider && profile.id != profileID {
            guard profileOperations[profile.id]?.kind == .activate else { continue }
            cancelProfileOperation(
                profileID: profile.id,
                revertKubeActivation: false
            )
        }
    }

    internal func cancelProviderOperations(
        for provider: CloudProvider,
        excludingProfileID: String,
        operationID: UUID
    ) {
        for profile in profiles where profile.provider == provider {
            guard let operation = profileOperations[profile.id],
                  operation.id != operationID || profile.id != excludingProfileID else {
                continue
            }
            cancelProfileOperation(profileID: profile.id)
        }
    }

    internal func cancelSupersededAWSOperations(previousProfileName: String) {
        for profile in profiles where profile.provider == .aws && profile.name == previousProfileName {
            guard let kind = profileOperations[profile.id]?.kind,
                  kind == .connect || kind == .exportCredentials || kind == .activate else {
                continue
            }
            cancelProfileOperation(profileID: profile.id)
            if kind == .connect,
               profiles.first(where: { $0.id == profile.id })?.status == .connecting {
                updateStatus(profile, status: .needsLogin)
            }
        }
    }

    internal func hasProfileOperation(for provider: CloudProvider) -> Bool {
        profiles.contains { profile in
            profile.provider == provider && profileOperations[profile.id] != nil
        }
    }

    @discardableResult
    internal func beginKubeContextActivation(
        target: String,
        kubeconfigPath: String,
        ownerProfileID: String,
        operationID: UUID
    ) -> UUID {
        let generation = UUID()
        pendingKubeContextActivation = KubeContextActivationIntent(
            generation: generation,
            ownerProfileID: ownerProfileID,
            operationID: operationID,
            target: target,
            previous: activeKubeContext,
            kubeconfigPath: kubeconfigPath
        )
        activeKubeContext = target
        defaults.set(target, forKey: "activeKubeContext")
        return generation
    }

    internal func cancelKubeContextActivation(
        ownerProfileID: String,
        operationID: UUID? = nil,
        revert: Bool
    ) {
        guard let intent = pendingKubeContextActivation,
              intent.ownerProfileID == ownerProfileID,
              operationID == nil || intent.operationID == operationID else {
            return
        }
        pendingKubeContextActivation = nil
        guard revert else { return }
        activeKubeContext = intent.previous
        if intent.previous.isEmpty {
            defaults.removeObject(forKey: "activeKubeContext")
        } else {
            defaults.set(intent.previous, forKey: "activeKubeContext")
        }
    }

    internal func completeKubeContextActivation(
        generation: UUID,
        result: CommandResult
    ) {
        guard let intent = pendingKubeContextActivation, intent.generation == generation else { return }
        guard result.exitCode == 0 else {
            pendingKubeContextActivation = nil
            activeKubeContext = intent.previous
            if intent.previous.isEmpty {
                defaults.removeObject(forKey: "activeKubeContext")
            } else {
                defaults.set(intent.previous, forKey: "activeKubeContext")
            }
            return
        }
        // Success remains pending until discovery observes the selected context.
    }

    internal func applyDiscoveredKubeContext(
        _: String,
        currentContextByPath: [String: String]
    ) {
        guard let intent = pendingKubeContextActivation else { return }
        guard let targetedCurrentContext = currentContextByPath[intent.kubeconfigPath] else { return }
        guard targetedCurrentContext == intent.target else { return }
        pendingKubeContextActivation = nil
    }
}
