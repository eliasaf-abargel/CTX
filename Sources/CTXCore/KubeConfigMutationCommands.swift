import Foundation

extension KubeConfigMutationService {
    /// Targets `kubeconfigPath` explicitly so mutations made while CTX uses a
    /// custom or multi-file KUBECONFIG are written back to the same file.
    internal func run(_ arguments: [String], kubeconfigPath: String?) async -> CommandResult {
        var args = arguments
        var environment = providerEnvironment()
        if let path = kubeconfigPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            args.insert(contentsOf: ["--kubeconfig", path], at: 0)
            environment["KUBECONFIG"] = path
        }
        do {
            var command = try kubectl.configurationCommand(arguments: args)
            command.environmentOverrides = environment
            let result = try await kubectl.run(command, timeout: CloudCommandTimeout.standard)
            return CommandResult(
                exitCode: result.exitCode,
                output: result.stdout + result.stderr
            )
        } catch {
            return CommandResult(exitCode: 127, output: error.localizedDescription)
        }
    }

    internal func validate(name: String, server: String) throws {
        guard !normalizedName(name).isEmpty else {
            throw KubeConfigMutationError.invalid("Context name is required")
        }
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeConfigMutationError.invalid("API server URL is required")
        }
    }

    internal func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal func validate(credentialUpdate: KubeConfigCredentialUpdate) throws {
        guard case .replace(let credential) = credentialUpdate else { return }
        switch credential {
        case .bearerToken(let token):
            guard let token, !token.isEmpty else {
                throw KubeConfigMutationError.invalid("A bearer token is required to replace credentials")
            }
        case .awsEKS(let region, _):
            guard !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KubeConfigMutationError.invalid("AWS region is required for EKS authentication")
            }
        case .internalProxy:
            break
        }
    }

    internal func setCluster(
        name: String,
        server: String,
        skipTLSVerification: Bool?,
        kubeconfigPath: String?,
        failurePrefix: String
    ) async throws {
        var args = [
            "config", "set-cluster", name,
            "--server=\(server)"
        ]
        if let skipTLSVerification {
            args.append("--insecure-skip-tls-verify=\(skipTLSVerification)")
        }
        let result = await run(args, kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, failurePrefix)
    }

    internal func setCredentials(
        _ userName: String,
        clusterName: String,
        credential: KubeConfigCredential,
        isReplacement: Bool = false,
        kubeconfigPath: String?,
        failurePrefix: String
    ) async throws {
        let args: [String]
        switch credential {
        case .internalProxy:
            return
        case .bearerToken(let token):
            guard let token, !token.isEmpty else {
                if isReplacement {
                    throw KubeConfigMutationError.invalid("A bearer token is required to replace credentials")
                }
                return
            }
            args = [
                "config", "set-credentials", userName,
                "--token=\(token)"
            ]
        case .awsEKS(let region, let profile):
            let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clusterName.isEmpty else {
                throw KubeConfigMutationError.invalid("Cluster name is required for AWS EKS authentication")
            }
            guard !region.isEmpty else {
                throw KubeConfigMutationError.invalid("AWS region is required for EKS authentication")
            }
            var execArgs = ["config", "set-credentials", userName]
            if isReplacement {
                // Clear a static token in the same write that installs the exec
                // plugin so a failed replacement cannot erase valid credentials.
                execArgs.append("--token=")
            }
            execArgs.append(contentsOf: [
                "--exec-command=aws",
                "--exec-api-version=client.authentication.k8s.io/v1beta1",
                "--exec-interactive-mode=Never",
                "--exec-arg=eks",
                "--exec-arg=get-token",
                "--exec-arg=--cluster-name",
                "--exec-arg=\(clusterName)",
                "--exec-arg=--region",
                "--exec-arg=\(region)"
            ])
            if let profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
                execArgs.append("--exec-arg=--profile")
                execArgs.append("--exec-arg=\(profile)")
            }
            args = execArgs
        }
        let result = await run(args, kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, failurePrefix)
    }

    /// Removes an obsolete exec plugin only after its replacement token is on disk.
    /// The probe reads the plugin command name, never a credential value.
    internal func clearStaleExecPlugin(for userName: String, kubeconfigPath: String?) async throws {
        let probe = await run([
            "config", "view",
            "-o", "json"
        ], kubeconfigPath: kubeconfigPath)
        guard probe.exitCode == 0 else { return }
        guard Self.userHasExecCommand(named: userName, in: probe.output) else { return }

        let result = await run(
            ["config", "unset", "users.\(escapedPropertySegment(userName)).exec"],
            kubeconfigPath: kubeconfigPath
        )
        guard result.exitCode != 0 else { return }
        throw KubeConfigMutationError.staleCredentialField(
            "The new bearer token was saved, but the previous credential plugin on user “\(userName)” could not be removed: \(KubernetesDiagnosticClassifier.sanitize(result.output))"
        )
    }

    internal func removeCredentials(
        _ userName: String,
        kubeconfigPath: String?,
        failurePrefix: String
    ) async throws {
        let result = await run(
            ["config", "unset", "users.\(escapedPropertySegment(userName))"],
            kubeconfigPath: kubeconfigPath
        )
        try requireSuccess(result, failurePrefix)
    }

    internal func setContext(
        name: String,
        cluster: String,
        user: String,
        namespace: String,
        clearNamespaceWhenEmpty: Bool,
        clearUserWhenEmpty: Bool = false,
        kubeconfigPath: String?,
        failurePrefix: String
    ) async throws {
        var args = [
            "config", "set-context", name,
            "--cluster=\(cluster)"
        ]
        if !user.isEmpty {
            args.append("--user=\(user)")
        } else if clearUserWhenEmpty {
            args.append("--user=")
        }
        if !namespace.isEmpty {
            args.append("--namespace=\(namespace)")
        } else if clearNamespaceWhenEmpty {
            args.append("--namespace=")
        }
        let result = await run(args, kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, failurePrefix)
    }

    internal func requireSuccess(_ result: CommandResult, _ prefix: String) throws {
        guard result.exitCode == 0 else {
            throw KubeConfigMutationError.invalid(
                "\(prefix): \(KubernetesDiagnosticClassifier.sanitize(result.output))"
            )
        }
    }

    internal func escapedPropertySegment(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
    }

    private static func userHasExecCommand(named userName: String, in output: String) -> Bool {
        struct Config: Decodable {
            struct NamedUser: Decodable {
                struct User: Decodable {
                    struct Exec: Decodable {
                        let command: String?
                    }
                    let exec: Exec?
                }
                let name: String
                let user: User
            }
            let users: [NamedUser]?
        }
        guard let data = output.data(using: .utf8),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              let user = config.users?.first(where: { $0.name == userName }) else {
            return false
        }
        return !(user.user.exec?.command ?? "").isEmpty
    }
}
