import Foundation

public final class ProfileCommandService: Sendable {
    private let runner: any CloudCommandRunning

    public init(runner: any CloudCommandRunning = CloudCommandRunner()) {
        self.runner = runner
    }

    public func activateGCPConfiguration(_ profile: CloudProfile) async -> CommandResult {
        await run(["gcloud", "config", "configurations", "activate", profile.name])
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
            return await runLogin(args, onOutput: onOutput)
        case .azure:
            var args = ["az", "login"]
            if !profile.roleName.isEmpty {
                args.append(contentsOf: ["--tenant", profile.roleName])
            }
            return await runLogin(args, onOutput: onOutput)
        case .kubernetes:
            if profile.usesStrongDM {
                let connectResult = await runLogin(["sdm", "connect", profile.name], onOutput: onOutput)
                if connectResult.exitCode == 0 {
                    return connectResult
                }
                if connectResult.output.contains("http://") || connectResult.output.contains("https://") {
                    return connectResult
                }
                var loginArgs = ["sdm", "login"]
                if let userEmail = email, !userEmail.isEmpty {
                    loginArgs.append(contentsOf: ["--email", userEmail])
                }
                let loginResult = await runLogin(loginArgs, onOutput: onOutput)
                if loginResult.output.contains("http://") || loginResult.output.contains("https://") {
                    return loginResult
                }
                _ = await runLogin(["sdm", "connect", profile.name], onOutput: onOutput)
                return loginResult
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
        case .aws:
            return await run(["aws", "sso", "logout", "--profile", profile.name])
        case .gcp:
            guard !profile.roleName.isEmpty else {
                return CommandResult(exitCode: 0, output: "")
            }
            return await run(["gcloud", "auth", "revoke", profile.roleName])
        case .azure:
            return await run(["az", "logout"])
        case .kubernetes:
            if profile.usesStrongDM {
                return await run(["sdm", "disconnect", profile.name])
            }
            return CommandResult(exitCode: 0, output: "")
        }
    }

    public func verify(_ profile: CloudProfile, activeKubeContext: String) async -> CommandResult {
        switch profile.provider {
        case .aws:
            return await run([
                "aws", "sts", "get-caller-identity",
                "--profile", profile.name,
                "--output", "json"
            ])
        case .gcp:
            return await run([
                "gcloud", "auth", "print-access-token",
                "--configuration", profile.name
            ])
        case .azure:
            let target = profile.accountID.isEmpty ? profile.name : profile.accountID
            return await run([
                "az", "account", "show",
                "--subscription", target,
                "--output", "json"
            ])
        case .kubernetes:
            guard profile.name == activeKubeContext else {
                return CommandResult(exitCode: 99, output: "Not active context")
            }
            if profile.usesStrongDM {
                let statusResult = await run(["sdm", "status"])
                if statusResult.exitCode == 0 {
                    let lines = statusResult.output.components(separatedBy: .newlines)
                    let lowerName = profile.name.lowercased()
                    for line in lines {
                        let lowerLine = line.lowercased()
                        if lowerLine.contains(lowerName) && (lowerLine.contains("connected") || lowerLine.contains("ready") || lowerLine.contains("active")) {
                            return CommandResult(exitCode: 0, output: "StrongDM connected (\(profile.name))")
                        }
                    }
                }
            }

            if profile.usesTeleport {
                let statusResult = await run(["tsh", "status"])
                if statusResult.exitCode == 0 && statusResult.output.lowercased().contains("logged in") {
                    return CommandResult(exitCode: 0, output: "Teleport connected")
                }
            }

            let versionResult = await run([
                "kubectl", "get", "--raw=/version",
                "--context", profile.name,
                "--request-timeout=10s"
            ])
            if versionResult.exitCode == 0 {
                return versionResult
            }

            if profile.usesStrongDM {
                return CommandResult(exitCode: 401, output: "StrongDM resource '\(profile.name)' is not connected. Run 'sdm connect \(profile.name)'.")
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
    private func run(
        _ arguments: [String],
        timeout: TimeInterval = CloudCommandTimeout.standard,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CommandResult {
        let result = await runner.run(arguments, timeout: timeout, onOutput: onOutput)
        guard result.exitCode != 0 else { return result }
        return CommandResult(
            exitCode: result.exitCode,
            output: KubernetesDiagnosticClassifier.sanitize(result.output)
        )
    }

    private func runLogin(_ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await run(arguments, timeout: CloudCommandTimeout.interactiveLogin, onOutput: onOutput)
    }
}
