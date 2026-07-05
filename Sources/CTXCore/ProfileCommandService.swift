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

    public func login(_ profile: CloudProfile) async -> CommandResult {
        switch profile.provider {
        case .aws:
            return await run(["aws", "sso", "login", "--profile", profile.name])
        case .gcp:
            return await run(["gcloud", "auth", "login", "--update-adc", "--configuration", profile.name])
        case .azure:
            var args = ["az", "login"]
            if !profile.roleName.isEmpty {
                args.append(contentsOf: ["--tenant", profile.roleName])
            }
            return await run(args)
        case .kubernetes:
            return CommandResult(exitCode: 0, output: "")
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
            return await run([
                "kubectl", "config", "get-contexts", profile.name,
                "--output", "name"
            ])
        }
    }

    public func exportAWSCredentials(for profile: CloudProfile) async -> CommandResult {
        await run([
            "aws", "configure", "export-credentials",
            "--profile", profile.name,
            "--output", "json"
        ])
    }

    private func run(_ arguments: [String]) async -> CommandResult {
        let result = await runner.run(arguments)
        guard result.exitCode != 0 else { return result }
        return CommandResult(
            exitCode: result.exitCode,
            output: KubernetesDiagnosticClassifier.sanitize(result.output)
        )
    }
}
