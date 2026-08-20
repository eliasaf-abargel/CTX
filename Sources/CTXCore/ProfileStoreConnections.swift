import Combine
import Foundation

extension ProfileStore {
    public func login(_ profile: CloudProfile) {
        // A missing CLI is not a failed login: ask for it before anything moves to
        // Connecting, so the user sees "install this" rather than a shell error.
        if let missing = CLITool.firstMissing(for: profile) {
            missingCLITool = MissingCLIToolRequest(tool: missing, profile: profile)
            return
        }
        manuallyDisconnectedProfiles.remove(profile.id)
        verificationErrors[profile.id] = nil
        if profile.provider == .kubernetes {
            setActive(profile, runActivation: false)
            activeKubeContext = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeKubeContext")
            updateStatus(profile, status: .connecting)

            let isSDM = profile.usesStrongDM
            let isTeleport = profile.usesTeleport

            Task {
                let startedAt = Date()
                let switchResult = await kubeConfigMutations.useContext(profile.name, kubeconfigPath: kubeconfigPath(for: profile.name))
                if switchResult.exitCode == 0 {
                    lastMessage = "Switched kube context to \(profile.name)"
                }

                if isSDM {
                    lastMessage = "Connecting to StrongDM for \(profile.name)..."
                    var sdmEmail = profile.token
                    if sdmEmail.isEmpty {
                        sdmEmail = profiles.first(where: { $0.roleName.contains("@") })?.roleName ?? ""
                    }
                    if sdmEmail.isEmpty && activeIdentityLabel.contains("@") {
                        sdmEmail = activeIdentityLabel
                    }
                    let sdmEmailFinal = sdmEmail.isEmpty ? nil : sdmEmail
                    let result = await profileCommands.login(profile, email: sdmEmailFinal, onOutput: { [weak self] output in
                        Task { @MainActor in
                            self?.openAuthURLIfPresent(output, email: sdmEmailFinal)
                        }
                    })
                    openAuthURLIfPresent(result.output, email: sdmEmailFinal)
                    lastCommandDuration = Date().timeIntervalSince(startedAt)
                    logConnectCall(step: "app_connect", kind: "sdm", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                    if result.exitCode == 0 {
                        lastLoginAt = Date()
                        lastMessage = "StrongDM connection successful"
                        Task { @MainActor in
                            self.activeInAppAuthURL = nil
                        }
                    }
                } else if isTeleport {
                    lastMessage = "Connecting to Teleport for \(profile.name)..."
                    let result = await profileCommands.login(profile, onOutput: { [weak self] output in
                        Task { @MainActor in
                            self?.openAuthURLIfPresent(output)
                        }
                    })
                    openAuthURLIfPresent(result.output)
                    lastCommandDuration = Date().timeIntervalSince(startedAt)
                    logConnectCall(step: "app_connect", kind: "teleport", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                    if result.exitCode == 0 {
                        lastLoginAt = Date()
                        lastMessage = "Teleport connection successful"
                        Task { @MainActor in
                            self.activeInAppAuthURL = nil
                        }
                    }
                }

                // Poll verification gently (every 3s for 24s total) while user completes Okta/SSO auth or tunnel opens
                var isConn = false
                for i in 0..<8 {
                    isConn = await verify(profile, isManualAttempt: i == 7)
                    if isConn {
                        Task { @MainActor in
                            self.activeInAppAuthURL = nil
                        }
                        break
                    }
                    if i < 7 {
                        updateStatus(profile, status: .connecting)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            }
            return
        }

        setActive(profile, runActivation: false)

        // Lookup the fresh status from the store's source of truth to avoid stale struct copies
        if let freshProfile = profiles.first(where: { $0.id == profile.id }),
           freshProfile.status == .connected {
            Task {
                await verify(freshProfile, isManualAttempt: true)
            }
            return
        }
        if profile.provider != .kubernetes || profile.roleName == "sdm-" + "user" {
            updateStatus(profile, status: .connecting)
        }

        Task {
            let startedAt = Date()
            let profileEmail = profile.roleName.contains("@") ? profile.roleName : (profile.accountID.contains("@") ? profile.accountID : (activeIdentityLabel.contains("@") ? activeIdentityLabel : nil))
            switch profile.provider {
            case .aws:
                // Whether this is a real sign-in is a fact on disk, not something to
                // infer from the CLI's stdout after the fact. A live token needs no
                // browser at all; an expired one with a refresh token is renewed
                // silently. Only a dead registration is a first-time login.
                if case .valid = awsSessionExpirations.ssoTokenState(for: profile) {
                    lastMessage = "AWS SSO session for \(profile.name) is still valid"
                    _ = await self.verify(profile, isManualAttempt: true)
                    return
                }
                lastMessage = "Starting AWS SSO login for \(profile.name)"
                let result = await profileCommands.login(profile, onOutput: { [weak self] output in
                    Task { @MainActor in
                        self?.openAuthURLIfPresent(output, email: profileEmail)
                    }
                })
                openAuthURLIfPresent(result.output, email: profileEmail)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                logConnectCall(step: "app_connect", kind: "aws", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "AWS SSO login completed"
                    Task { @MainActor in
                        self.activeInAppAuthURL = nil
                        self.setActive(profile, runActivation: false)
                    }
                    _ = await self.verify(profile, isManualAttempt: true)
                } else {
                    reportLoginFailure(result, for: profile)
                }
            case .gcp:
                gcpManuallyClearedByUser = false
                // `gcloud auth print-access-token` refreshes a stored session on its
                // own, so a passing verify is proof no browser is needed — the same
                // rule as the AWS token check, expressed in gcloud's own terms.
                if await self.verify(profile, isManualAttempt: true) {
                    lastMessage = "GCP session for \(profile.name) is still valid"
                    return
                }
                lastMessage = "Starting gcloud auth login for \(profile.name)"
                let result = await profileCommands.login(profile, onOutput: { [weak self] output in
                    Task { @MainActor in
                        self?.openAuthURLIfPresent(output, email: profileEmail)
                    }
                })
                openAuthURLIfPresent(result.output, email: profileEmail)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                logConnectCall(step: "app_connect", kind: "gcp", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "GCP auth login completed"
                    Task { @MainActor in
                        self.activeInAppAuthURL = nil
                        self.setActive(profile, runActivation: false)
                    }
                    _ = await self.verify(profile, isManualAttempt: true)
                } else {
                    reportLoginFailure(result, for: profile)
                }
            case .azure:
                // `az account show` succeeds off the MSAL token cache, refreshing
                // silently; no reason to send the user through a browser for it.
                if await self.verify(profile, isManualAttempt: true) {
                    if !profile.accountID.isEmpty {
                        _ = await profileCommands.selectAzureSubscription(profile)
                    }
                    lastMessage = "Azure session for \(profile.name) is still valid"
                    return
                }
                lastMessage = "Starting az login for \(profile.name)"
                let result = await profileCommands.login(profile, onOutput: { [weak self] output in
                    Task { @MainActor in
                        self?.openAuthURLIfPresent(output, email: profileEmail)
                    }
                })
                openAuthURLIfPresent(result.output, email: profileEmail)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                logConnectCall(step: "app_connect", kind: "azure", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "Azure login completed"
                    Task { @MainActor in
                        self.activeInAppAuthURL = nil
                        self.setActive(profile, runActivation: false)
                    }
                    if !profile.accountID.isEmpty {
                        _ = await profileCommands.selectAzureSubscription(profile)
                    }
                    _ = await self.verify(profile, isManualAttempt: true)
                } else {
                    reportLoginFailure(result, for: profile)
                }
            case .kubernetes:
                let isSDM = profile.usesStrongDM
                let isTeleport = profile.usesTeleport

                if isSDM {
                    lastMessage = "Connecting to StrongDM for \(profile.name)..."
                    var sdmEmail = profile.token
                    if sdmEmail.isEmpty {
                        sdmEmail = profiles.first(where: { $0.roleName.contains("@") })?.roleName ?? ""
                    }
                    if sdmEmail.isEmpty && activeIdentityLabel.contains("@") {
                        sdmEmail = activeIdentityLabel
                    }
                    let sdmEmailFinal = sdmEmail.isEmpty ? nil : sdmEmail
                    let result = await profileCommands.login(profile, email: sdmEmailFinal, onOutput: { [weak self] output in
                        Task { @MainActor in
                            self?.openAuthURLIfPresent(output, email: sdmEmailFinal)
                        }
                    })
                    openAuthURLIfPresent(result.output, email: sdmEmailFinal)
                    lastCommandDuration = Date().timeIntervalSince(startedAt)
                    logConnectCall(step: "app_connect", kind: "sdm", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                    if result.exitCode == 0 {
                        lastLoginAt = Date()
                        lastMessage = "StrongDM connection successful"
                        Task { @MainActor in
                            self.activeInAppAuthURL = nil
                        }
                    } else {
                        reportLoginFailure(result, for: profile)
                    }
                } else if isTeleport {
                    lastMessage = "Connecting to Teleport for \(profile.name)..."
                    let result = await profileCommands.login(profile, onOutput: { [weak self] output in
                        Task { @MainActor in
                            self?.openAuthURLIfPresent(output)
                        }
                    })
                    openAuthURLIfPresent(result.output)
                    lastCommandDuration = Date().timeIntervalSince(startedAt)
                    logConnectCall(step: "app_connect", kind: "teleport", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                    if result.exitCode == 0 {
                        lastLoginAt = Date()
                        lastMessage = "Teleport connection successful"
                        Task { @MainActor in
                            self.activeInAppAuthURL = nil
                        }
                    } else {
                        reportLoginFailure(result, for: profile)
                    }
                } else {
                    lastMessage = "Kubernetes context \(profile.name) selected"
                }
            }
            var isConn = false
            for i in 0..<8 {
                isConn = await verify(profile, isManualAttempt: i == 7)
                if isConn { break }
                if i < 7 {
                    updateStatus(profile, status: .connecting)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    public func logout(_ profile: CloudProfile) {
        manuallyDisconnectedProfiles.insert(profile.id)
        switch profile.provider {
        case .aws:
            updateStatus(profile, status: .disconnecting)
            if activeAWSProfile == profile.name {
                clearActive(for: .aws)
            }
            Task {
                lastMessage = "Logging out AWS profile \(profile.name)..."
                let result = await profileCommands.logout(profile)
                updateStatus(profile, status: result.exitCode == 0 ? .needsLogin : status(for: result))
                refresh()
            }
        case .gcp:
            updateStatus(profile, status: .disconnecting)
            if activeGCPProfile == profile.name {
                clearActive(for: .gcp)
            }
            Task {
                lastMessage = "Revoking GCP configuration \(profile.name)..."
                let result = await profileCommands.logout(profile)
                updateStatus(profile, status: result.exitCode == 0 ? .needsLogin : status(for: result))
                refresh()
            }
        case .azure:
            updateStatus(profile, status: .disconnecting)
            if activeAzureProfile == profile.name {
                clearActive(for: .azure)
            }
            Task {
                lastMessage = "Signing out Azure \(profile.name)..."
                let result = await profileCommands.logout(profile)
                updateStatus(profile, status: result.exitCode == 0 ? .needsLogin : status(for: result))
                refresh()
            }
        case .kubernetes:
            if activeKubeContext == profile.name {
                clearActive(for: .kubernetes)
            }
            let isSDM = profile.usesStrongDM
            let isTeleport = profile.usesTeleport

            updateStatus(profile, status: .disconnecting)
            Task {
                let logoutKubeconfigPath = kubeconfigPath(for: profile.name)
                lastMessage = "Cleared current kube context"
                _ = await kubeConfigMutations.clearCurrentContext(kubeconfigPath: logoutKubeconfigPath)
                if isSDM || isTeleport {
                    lastMessage = "Disconnecting \(isSDM ? "StrongDM" : "Teleport") resource \(profile.name)..."
                    _ = await profileCommands.logout(profile)
                }
                updateStatus(profile, status: .needsLogin)
                refresh()
            }
        }
    }

    /// A login command exiting non-zero is the authoritative "it did not happen".
    /// Leaving the auth modal up on whatever page the provider last redirected to
    /// is what left profiles sitting at Connecting with no way to tell whether the
    /// sign-in worked.
    ///
    /// Not for StrongDM/Teleport: those exit non-zero *while* the user is still
    /// finishing the sign-in in the modal their own output opened, and the verify
    /// poll is what resolves them. The cloud CLIs only exit once the flow is over.
    internal func reportLoginFailure(_ result: CommandResult, for profile: CloudProfile) {
        if profile.provider != .kubernetes {
            activeInAppAuthURL = nil
        }
        var message = result.output
        // "I just logged in and it still says the token is missing" is almost
        // always the credentials file overriding the config, not a failed login.
        if profile.provider == .aws, let conflict = AWSCredentialsFileAudit.conflict(for: profile.name) {
            message += "\n\n" + conflict.explanation
        }
        lastMessage = message
        connectionErrorMessage = message
    }

    internal func logConnectCall(step: String, kind: String, profileID: String, started: Date, outcome: String) {
        CTXPerfLog.log(
            step: step,
            contextID: profileID,
            namespace: "cluster",
            kind: kind,
            cache: .none,
            durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            outcome: outcome == "success" ? .success : .error
        )
    }

    internal func openAuthURLIfPresent(_ text: String, email: String? = nil) {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        for match in matches ?? [] {
            if let url = match.url, url.scheme?.hasPrefix("http") == true {
                if let host = url.host?.lowercased() {
                    if host == "127.0.0.1" || host == "localhost" {
                        continue
                    }
                }
                Task { @MainActor in
                    self.activeInAppAuthEmail = email
                    self.activeInAppAuthURL = url
                }
                break
            }
        }
    }
}
