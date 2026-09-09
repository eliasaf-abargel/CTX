import Foundation

public final class ProfileCommandService: Sendable {
    private let runner: any CloudCommandRunning
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let providerEnvironment: @Sendable () -> [String: String]

    public init(
        runner: any CloudCommandRunning = CloudCommandRunner(),
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        providerEnvironment: @escaping @Sendable () -> [String: String] = {
            ProviderCommandEnvironment.overrides()
        }
    ) {
        self.runner = runner
        self.kubectl = kubectl
        self.providerEnvironment = providerEnvironment
    }

    public func linkedAWSProfile(for context: KubernetesContextProfile) async -> String? {
        do {
            var command = try kubectl.inspectionCommand(
                context: context.contextName,
                arguments: ["--kubeconfig", context.kubeconfigPath, "config", "view", "--minify", "-o", "json"]
            )
            command.environmentOverrides["KUBECONFIG"] = context.kubeconfigPath
            let result = try await kubectl.run(command, timeout: 10)
            guard result.exitCode == 0 else { return nil }
            return Self.explicitAWSProfile(in: Data(result.stdout.utf8))
        } catch { return nil }
    }

    public func activateGCPConfiguration(_ profile: CloudProfile) async -> CommandResult {
        await run(["gcloud", "config", "configurations", "activate", profile.name])
    }

    /// Refreshes Application Default Credentials directly — the credential a
    /// kubectl exec plugin like `gke-gcloud-auth-plugin` actually reads, and
    /// which `login(_:)` only reaches indirectly through one named gcloud
    /// configuration. Unscoped on purpose: it works even when CTX has no GCP
    /// profile on file for whatever context needs it refreshed.
    public func refreshGCPApplicationDefaultCredentials(onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await runLogin(["gcloud", "auth", "application-default", "login"], onOutput: onOutput)
    }

    public func activateAzureSubscription(_ profile: CloudProfile) async -> CommandResult {
        let target = profile.accountID.isEmpty ? profile.name : profile.accountID
        return await run(["az", "account", "set", "--subscription", target])
    }

    public func login(_ profile: CloudProfile, email: String? = nil, onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        switch profile.provider {
        case .aws:
            // `--no-browser` keeps Safari out of it. Without it the CLI opens the
            // same one-shot authorize URL we render in the in-app modal, both race
            // for the single localhost callback, and the user signs in twice.
            let result = await runLogin(["aws", "sso", "login", "--profile", profile.name, "--no-browser"], onOutput: onOutput)
            if result.exitCode != 0, result.output.contains("--no-browser") {
                // ponytail: aws-cli < 2.9 has no such flag; only then fall back.
                return await runLogin(["aws", "sso", "login", "--profile", profile.name], onOutput: onOutput)
            }
            return result
        case .gcp:
            var args = ["gcloud", "auth", "login", "--configuration", profile.name]
            let emailCandidate = profile.accountID.contains("@") ? profile.accountID : (profile.roleName.contains("@") ? profile.roleName : "")
            if !emailCandidate.isEmpty {
                args.append(contentsOf: ["--account", emailCandidate])
            }
            let loginResult = await runLogin(args, onOutput: onOutput)
            guard loginResult.exitCode == 0 else { return loginResult }
            // `gcloud auth login` only refreshes the CLI's own credentials. Any client
            // library or external tool (Terraform, gcloud SDKs, other agents) reads
            // Application Default Credentials instead, which live in a separate file
            // and need their own login step — otherwise they keep failing even though
            // CTX and `gcloud` itself look fully connected.
            return await runLogin(["gcloud", "auth", "application-default", "login"], onOutput: onOutput)
        case .azure:
            var args = ["az", "login"]
            if !profile.roleName.isEmpty {
                args.append(contentsOf: ["--tenant", profile.roleName])
            }
            return await runLogin(args, onOutput: onOutput)
        case .kubernetes:
            if profile.usesStrongDM {
                return await loginStrongDM(profile, email: email, onOutput: onOutput)
            } else if profile.usesTeleport {
                let loginResult = await runLogin(["tsh", "kube", "login", profile.name], onOutput: onOutput)
                if loginResult.exitCode == 0 {
                    return loginResult
                }
                let authResult = await runLogin(["tsh", "login"], onOutput: onOutput)
                guard authResult.exitCode == 0 else {
                    return authResult
                }
                return await runLogin(["tsh", "kube", "login", profile.name], onOutput: onOutput)
            } else {
                return CommandResult(exitCode: 0, output: "Context selected")
            }
        }
    }

    public func selectAzureSubscription(_ profile: CloudProfile) async -> CommandResult {
        guard !profile.accountID.isEmpty else {
            return CommandResult(exitCode: 0, output: "")
        }
        return await run(["az", "account", "set", "--subscription", profile.accountID])
    }

    public func logout(_ profile: CloudProfile) async -> CommandResult {
        switch profile.provider {
        case .aws, .gcp, .azure:
            return CommandResult(exitCode: 0, output: "")
        case .kubernetes:
            if profile.usesStrongDM {
                return await disconnectStrongDM(profile)
            }
            if profile.usesTeleport {
                return await run(["tsh", "kube", "logout", profile.name])
            }
            return CommandResult(exitCode: 0, output: "")
        }
    }

    public func signOutFromProvider(_ profile: CloudProfile) async -> CommandResult {
        switch profile.provider {
        case .aws:
            return await run(["aws", "sso", "logout"])
        case .gcp:
            let account = [profile.roleName, profile.accountID].first { $0.contains("@") }
            guard let account else {
                return CommandResult(exitCode: 2, output: "The GCP account is ambiguous.")
            }
            return await run([
                "gcloud", "auth", "revoke", account,
                "--configuration", profile.name
            ])
        case .azure:
            return await run(["az", "logout"])
        case .kubernetes:
            return CommandResult(exitCode: 2, output: "Kubernetes has no global provider sign-out.")
        }
    }

    public func verify(
        _ profile: CloudProfile,
        activeKubeContext: String,
        kubeconfigPath: String? = nil
    ) async -> CommandResult {
        switch profile.provider {
        case .aws:
            return await run([
                "aws", "sts", "get-caller-identity",
                "--profile", profile.name,
                "--output", "json"
            ])
        case .gcp:
            let result = await run([
                "gcloud", "config", "configurations", "describe", profile.name,
                "--format=value(properties.core.account)",
                "--quiet"
            ])
            guard result.exitCode == 0 else { return result }
            let account = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedAccount = [profile.roleName, profile.accountID]
                .first { $0.contains("@") }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !account.isEmpty, account != "(unset)" else {
                return CommandResult(exitCode: 1, output: "No account is configured for \(profile.name).")
            }
            guard expectedAccount.isEmpty || account.caseInsensitiveCompare(expectedAccount) == .orderedSame else {
                return CommandResult(
                    exitCode: 1,
                    output: "Configuration \(profile.name) is associated with a different account."
                )
            }
            // Everything above only reads a local config file — it says nothing
            // about whether the refresh token behind that account still works.
            // This is the actual liveness check: cheap, non-interactive, and it
            // fails immediately instead of opening a browser if the token was
            // revoked or expired.
            let tokenCheck = await run([
                "gcloud", "auth", "print-access-token",
                "--account", account,
                "--quiet"
            ])
            guard tokenCheck.exitCode == 0 else {
                return CommandResult(
                    exitCode: 1,
                    output: "GCP credentials for \(account) have expired or were revoked. Run gcloud auth login."
                )
            }
            return CommandResult(exitCode: 0, output: "")
        case .azure:
            let target = profile.accountID.isEmpty ? profile.name : profile.accountID
            let result = await run([
                "az", "account", "show",
                "--subscription", target,
                "--output", "json"
            ])
            guard result.exitCode == 0 else { return result }
            // Same story as GCP: `account show` only reads the local profile
            // cache. `get-access-token` is the real, non-interactive check.
            let tokenCheck = await run([
                "az", "account", "get-access-token",
                "--subscription", target,
                "--output", "none"
            ])
            guard tokenCheck.exitCode == 0 else {
                return CommandResult(
                    exitCode: 1,
                    output: "Azure credentials for \(target) have expired or require re-authentication. Run az login."
                )
            }
            return CommandResult(exitCode: 0, output: "")
        case .kubernetes:
            guard profile.name == activeKubeContext else {
                return CommandResult(exitCode: 99, output: "Not active context")
            }
            if profile.usesStrongDM {
                let statusResult = await run(["sdm", "status"])
                guard statusResult.exitCode == 0 else { return statusResult }
                // Broker authentication alone does not prove the cluster API is reachable.

            }

            if profile.usesTeleport {
                let statusResult = await run(["tsh", "status"])
                if statusResult.exitCode == 0 && statusResult.output.lowercased().contains("logged in") {
                    return CommandResult(exitCode: 0, output: "Teleport connected")
                }
            }

            let versionResult = await runKubectl(
                context: profile.name,
                kubeconfigPath: kubeconfigPath,
                arguments: ["get", "--raw=/version", "--request-timeout=10s"]
            )
            if versionResult.exitCode == 0 {
                return versionResult
            }

            return versionResult
        }
    }

    public func exportAWSCredentials(for profile: CloudProfile) async -> CommandResult {
        await run([
            "aws", "configure", "export-credentials",
            "--profile", profile.name,
            "--output", "json"
        ])
    }

    /// Verification, activation and logout calls are expected to answer promptly;
    /// `login(...)` overrides this with `CloudCommandTimeout.interactiveLogin`,
    /// because an SSO flow legitimately waits on the user finishing in a browser.
    internal func run(
        _ arguments: [String],
        timeout: TimeInterval = CloudCommandTimeout.standard,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CommandResult {
        let started = Date()
        let result = await runner.run(
            arguments,
            environmentOverrides: providerEnvironment(),
            timeout: timeout,
            onOutput: onOutput
        )
        LocalDiagnostics.shared.recordCommand(arguments: arguments, result: result, durationMs: Int(Date().timeIntervalSince(started) * 1000))
        guard result.exitCode != 0 else { return result }
        return CommandResult(
            exitCode: result.exitCode,
            output: KubernetesDiagnosticClassifier.sanitize(result.output)
        )
    }

    internal func runLogin(_ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await run(arguments, timeout: CloudCommandTimeout.interactiveLogin, onOutput: onOutput)
    }

    private func runKubectl(
        context: String,
        kubeconfigPath: String?,
        arguments: [String]
    ) async -> CommandResult {
        var commandArguments = arguments
        var environment = providerEnvironment()
        if let path = kubeconfigPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            commandArguments.insert(contentsOf: ["--kubeconfig", path], at: 0)
            environment["KUBECONFIG"] = path
        }

        do {
            var command = try kubectl.inspectionCommand(context: context, arguments: commandArguments)
            command.environmentOverrides = environment
            let result = try await kubectl.run(command, timeout: 10)
            let output = result.stdout + result.stderr
            LocalDiagnostics.shared.recordCommand(arguments: ["kubectl", "get"], result: CommandResult(exitCode: result.exitCode, output: output), durationMs: 0)
            return CommandResult(
                exitCode: result.exitCode,
                output: result.exitCode == 0 ? output : KubernetesDiagnosticClassifier.sanitize(output)
            )
        } catch {
            return CommandResult(exitCode: 127, output: error.localizedDescription)
        }
    }
}
