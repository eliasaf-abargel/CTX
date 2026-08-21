import Combine
import Foundation

extension ProfileStore {
    @discardableResult
    public func verify(
        _ profile: CloudProfile,
        isManualAttempt: Bool = false,
        operationID: UUID? = nil,
        from origin: ProfilePresentationSurface = .mainWindow
    ) async -> Bool {
        guard canPublishLifecycleState(for: profile.id, operationID: operationID) else { return false }
        let startedAt = Date()
        let result = await profileCommands.verify(
            profile,
            activeKubeContext: activeKubeContext,
            kubeconfigPath: profile.provider == .kubernetes ? kubeconfigPath(for: profile.name) : nil
        )
        guard canPublishLifecycleState(for: profile.id, operationID: operationID) else { return false }
        lastCommandDuration = Date().timeIntervalSince(startedAt)
        let step = profile.provider == .kubernetes ? "verify_kubectl" : "app_connect"
        logConnectCall(step: step, kind: profile.provider.rawValue.lowercased(), profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")

        let isConnected = result.exitCode == 0
        let isManuallyDisconnected = manuallyDisconnectedProfiles.contains(profile.id)
        let effectiveConnection = isConnected && !isManuallyDisconnected
        let oldStatus = profiles.first(where: { $0.id == profile.id })?.status ?? .unknown

        if effectiveConnection {
            verificationErrors[profile.id] = nil
            if profile.provider == .aws {
                if profile.name == activeAWSProfile,
                   let identity = awsCredentials.identity(fromCallerIdentityOutput: result.output) {
                    if awsIdentity != identity {
                        awsIdentity = identity
                    }
                }
            }

        }

        let newStatus: ProfileStatus
        if effectiveConnection {
            newStatus = .connected
            verificationErrors[profile.id] = nil
        } else {
            if profile.provider == .aws && profile.name == activeAWSProfile {
                awsIdentity = ""
            }
            if oldStatus == .connecting && !isManualAttempt {
                newStatus = .connecting
            } else if profile.provider == .kubernetes {
                if result.exitCode == 99 {
                    newStatus = .unknown
                    verificationErrors[profile.id] = nil
                } else {
                    newStatus = status(for: result)
                    verificationErrors[profile.id] = result.output.isEmpty ? nil : result.output
                }
            } else {
                newStatus = status(for: result)
                if isManualAttempt {
                    verificationErrors[profile.id] = result.output
                } else {
                    verificationErrors[profile.id] = nil
                }
            }
        }

        updateStatus(profile, status: newStatus, operationID: operationID)
        if isManualAttempt, operationID == nil, !isConnected, !result.output.isEmpty {
            report(result.output, title: "Verification Failed", from: origin)
        }
        return effectiveConnection
    }

    internal func canPublishLifecycleState(for profileID: String, operationID: UUID?) -> Bool {
        if let operationID {
            return isCurrentOperation(profileID: profileID, operationID: operationID)
        }
        return !hasProfileOperation(profileID: profileID)
    }

    internal func updateStatus(
        _ profile: CloudProfile,
        status: ProfileStatus,
        operationID: UUID? = nil
    ) {
        guard canPublishLifecycleState(for: profile.id, operationID: operationID) else { return }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        guard profiles[index].status != status else { return }
        profiles[index].status = status
        checkAllSessionsExpiration()
    }

    internal func status(for result: CommandResult) -> ProfileStatus {
        result.exitCode == 127 || result.output.localizedCaseInsensitiveContains("No such file")
            ? .missingCli
            : .needsLogin
    }

    public func verifyAllProfiles() {
        guard verificationTask == nil else {
            pendingVerificationRequest = true
            return
        }
        verificationTask = Task { [weak self] in
            guard let self else { return }
            await self.runVerificationSweep()
            self.verificationTask = nil
            if self.pendingVerificationRequest {
                self.pendingVerificationRequest = false
                self.verifyAllProfiles()
            }
        }
    }

    internal func runVerificationSweep() async {
        _ = await withBoundedConcurrency(over: profiles, limit: 3) { profile in
            await self.verify(profile)
        }
        await MainActor.run {
            self.lastVerifiedAt = Date()
        }
    }

    internal func checkAllSessionsExpiration() {
        guard !isCheckingSessionExpiration else { return }
        isCheckingSessionExpiration = true
        let profiles = self.profiles
        let service = awsSessionExpirations
        Task { [weak self] in
            let snapshot = await Task.detached { service.snapshot(for: profiles) }.value
            guard let self else { return }
            self.isCheckingSessionExpiration = false
            guard let snapshot else { return }
            self.applySessionExpiration(snapshot)
        }
    }

    internal func applySessionExpiration(_ snapshot: AWSSessionExpirationSnapshot) {
        let now = Date()

        if snapshot.newestCacheModificationDate > lastCacheCheckTime {
            lastCacheCheckTime = snapshot.newestCacheModificationDate
            verifyAllProfiles()
        }

        for profile in profiles where profile.provider == .aws {
            guard let expiresAt = snapshot.expiryByProfileName[profile.name] else { continue }
            let timeLeft = expiresAt.timeIntervalSince(now)

            if timeLeft <= 0 {
                if profile.status == .connected {
                    updateStatus(profile, status: .needsLogin)
                }
                if profile.name == activeAWSProfile {
                    awsIdentity = ""
                }
            }

            if profile.name == activeAWSProfile {
                activeAWSExpiresAt = expiresAt
                if timeLeft > -10 && timeLeft <= 120 {
                    if lastExpirationWarningTime != expiresAt {
                        let isExpired = timeLeft <= 0
                        triggerExpirationWarning(profileName: profile.name, expired: isExpired)
                        lastExpirationWarningTime = expiresAt
                    }
                }
            }
        }
    }

    public func sessionExpiry(for profile: CloudProfile) -> Date? {
        awsSessionExpirations.sessionExpiry(for: profile)
    }

    public func markKubernetesContextNeedsLogin(contextName: String, reason: String) {
        guard let profile = profiles.first(where: { $0.provider == .kubernetes && $0.name == contextName }) else { return }
        verificationErrors[profile.id] = reason
        updateStatus(profile, status: .needsLogin)
    }

    internal func triggerExpirationWarning(profileName: String, expired: Bool) {
        if expired {
            expirationWarningMessage = "\(profileName): Session Expired"
        } else {
            expirationWarningMessage = "\(profileName): Session Expiring"
        }
        showExpirationWarning = true
        notifications.sendAWSExpiration(profileName: profileName, expired: expired)

        expirationWarningTask?.cancel()
        expirationWarningTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.showExpirationWarning = false
        }
    }
}
