import Foundation

extension ProfileStore {
    public func login(
        _ profile: CloudProfile,
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        if let missing = missingCLIToolResolver(profile) {
            cancelProfileOperation(profileID: profile.id)
            present(.missingCLI(MissingCLIToolRequest(tool: missing, profile: profile)), from: origin)
            return
        }
        _ = startProfileOperation(for: profile, kind: .connect, origin: origin) { @MainActor [weak self] operationID in
            guard let self else { return }
            await self.runLogin(profile, operationID: operationID, origin: origin)
        }
    }

    public func retryMissingCLI(_ request: MissingCLIToolRequest, from origin: ProfilePresentationSurface) {
        dismissPresentation(from: origin)
        login(request.profile, from: origin)
    }

    public func logout(
        _ profile: CloudProfile,
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        _ = startProfileOperation(for: profile, kind: .disconnect, origin: origin) { @MainActor [weak self] operationID in
            guard let self else { return }
            await self.runLogout(profile, operationID: operationID, origin: origin)
        }
    }

    private func runLogin(
        _ profile: CloudProfile,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) async {
        guard !Task.isCancelled,
              isCurrentOperation(profileID: profile.id, operationID: operationID) else {
            return
        }
        clearManualDisconnect(profile.id)
        verificationErrors[profile.id] = nil
        setActiveState(profile, operationID: operationID)
        updateStatus(profile, status: .connecting, operationID: operationID)

        if profile.provider == .kubernetes {
            let targetKubeconfigPath = kubeconfigPath(for: profile.name)
                ?? kubeConfigDiscoveryService.candidatePaths().first?.path
                ?? ""
            let activationGeneration = beginKubeContextActivation(
                target: profile.name,
                kubeconfigPath: targetKubeconfigPath,
                ownerProfileID: profile.id,
                operationID: operationID
            )
            let switchResult = await kubeConfigMutations.useContext(
                profile.name,
                kubeconfigPath: targetKubeconfigPath
            )
            guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
            completeKubeContextActivation(generation: activationGeneration, result: switchResult)
            guard switchResult.exitCode == 0 else {
                reportLoginFailure(switchResult, for: profile, operationID: operationID, origin: origin)
                updateStatus(profile, status: status(for: switchResult), operationID: operationID)
                return
            }
            lastMessage = "Switched kube context to \(profile.name)"
            refreshImmediately(runVerification: false)
        }

        let startedAt = Date()
        let email = profile.roleName.contains("@")
            ? profile.roleName
            : (profile.accountID.contains("@") ? profile.accountID : (activeIdentityLabel.contains("@") ? activeIdentityLabel : nil))

        switch profile.provider {
        case .aws:
            if case .valid = awsSessionExpirations.ssoTokenState(for: profile) {
                lastMessage = "AWS SSO session for \(profile.name) is still valid"
                if await verify(profile, isManualAttempt: true, operationID: operationID) {
                    _ = await performAWSCredentialExport(
                        for: profile,
                        operationID: operationID,
                        origin: origin
                    )
                }
                return
            }
            lastMessage = "Starting AWS SSO login for \(profile.name)"
        case .gcp:
            if await verify(profile, isManualAttempt: true, operationID: operationID) {
                guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
                lastMessage = "GCP session for \(profile.name) is still valid"
                return
            }
            guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
            lastMessage = "Starting gcloud auth login for \(profile.name)"
        case .azure:
            if await verify(profile, isManualAttempt: true, operationID: operationID) {
                guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
                if !profile.accountID.isEmpty {
                    _ = await profileCommands.selectAzureSubscription(profile)
                }
                guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
                lastMessage = "Azure session for \(profile.name) is still valid"
                return
            }
            guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
            lastMessage = "Starting az login for \(profile.name)"
        case .kubernetes:
            if profile.usesStrongDM {
                lastMessage = "Connecting to StrongDM for \(profile.name)..."
            } else if profile.usesTeleport {
                lastMessage = "Connecting to Teleport for \(profile.name)..."
            } else {
                lastMessage = "Kubernetes context \(profile.name) selected"
            }
        }

        let result = await profileCommands.login(
            profile,
            email: email,
            onOutput: { [weak self] output in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
                    self.openAuthURLIfPresent(
                        output,
                        email: email,
                        operationID: operationID,
                        profileID: profile.id,
                        origin: origin
                    )
                }
            }
        )
        guard isCurrentOperation(profileID: profile.id, operationID: operationID) else { return }
        openAuthURLIfPresent(
            result.output,
            email: email,
            operationID: operationID,
            profileID: profile.id,
            origin: origin
        )
        lastCommandDuration = Date().timeIntervalSince(startedAt)
        logConnectCall(step: "app_connect", kind: profile.provider.rawValue.lowercased(), profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
        guard result.exitCode == 0 else {
            reportLoginFailure(result, for: profile, operationID: operationID, origin: origin)
            updateStatus(profile, status: status(for: result), operationID: operationID)
            return
        }

        lastLoginAt = Date()
        dismissInAppAuth(profileID: profile.id, operationID: operationID, origin: origin)
        setActiveState(profile, operationID: operationID)
        lastMessage = "\(profile.provider.rawValue) login completed"

        await pollForConnectedProfile(profile, operationID: operationID, origin: origin)
    }

    /// One-click remediation for the two Kubernetes auth failures CTX can
    /// actually fix without guessing: a mid-work GCP/AWS credential expiry
    /// shouldn't force the user out to a terminal. Anchored on the context's
    /// own `.kubernetes` profile so status updates and the in-app auth window
    /// use the same machinery as a normal login.
    public func reconnectKubernetesAuth(
        for context: KubernetesContextProfile,
        category: KubernetesDiagnosticCategory,
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        guard let anchorProfile = profiles.first(where: { $0.provider == .kubernetes && $0.name == context.contextName }) else { return }

        switch category {
        case .gcpAuthExpired:
            _ = startProfileOperation(for: anchorProfile, kind: .connect, origin: origin) { @MainActor [weak self] operationID in
                guard let self else { return }
                self.updateStatus(anchorProfile, status: .connecting, operationID: operationID)
                self.lastMessage = "Refreshing GCP credentials for \(context.contextName)..."
                let result = await self.profileCommands.refreshGCPApplicationDefaultCredentials { [weak self] output in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentOperation(profileID: anchorProfile.id, operationID: operationID) else { return }
                        self.openAuthURLIfPresent(output, operationID: operationID, profileID: anchorProfile.id, origin: origin)
                    }
                }
                guard self.isCurrentOperation(profileID: anchorProfile.id, operationID: operationID) else { return }
                self.dismissInAppAuth(profileID: anchorProfile.id, operationID: operationID, origin: origin)
                guard result.exitCode == 0 else {
                    self.reportLoginFailure(result, for: anchorProfile, operationID: operationID, origin: origin)
                    self.updateStatus(anchorProfile, status: .needsLogin, operationID: operationID)
                    return
                }
                self.lastMessage = "GCP credentials refreshed"
                // Not `.connected` — that would claim more than an ADC refresh
                // proves. The real kubectl check below settles the true status.
                self.verifyAllProfiles()
            }
        case .awsSSOExpired:
            if anchorProfile.usesStrongDM || anchorProfile.usesTeleport {
                login(anchorProfile, from: origin)
                return
            }
            _ = startProfileOperation(for: anchorProfile, kind: .connect, origin: origin) { @MainActor [weak self] operationID in
                guard let self else { return }
                let linkedName = await self.profileCommands.linkedAWSProfile(for: context)
                guard self.isCurrentOperation(profileID: anchorProfile.id, operationID: operationID) else { return }
                if let linkedName, let awsProfile = self.profiles.first(where: { $0.provider == .aws && $0.name == linkedName }) {
                    self.login(awsProfile, from: origin)
                } else {
                    self.report(
                        "This context does not specify a known AWS profile. Select its AWS profile explicitly in the sidebar.",
                        title: "AWS Reconnect",
                        from: origin
                    )
                }
            }
        default:
            break
        }
    }
}
