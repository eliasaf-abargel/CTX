import Foundation

public struct KubernetesApplyResult: Equatable, Sendable {
    public let success: Bool
    public let isDryRun: Bool
    public let message: String
    public let errorDetails: String?
    public let stdout: String
    public let appliedYAML: String?

    public init(
        success: Bool,
        isDryRun: Bool,
        message: String,
        errorDetails: String? = nil,
        stdout: String = "",
        appliedYAML: String? = nil
    ) {
        self.success = success
        self.isDryRun = isDryRun
        self.message = message
        self.errorDetails = errorDetails
        self.stdout = stdout
        self.appliedYAML = appliedYAML
    }
}

public protocol KubernetesYAMLApplying: Sendable {
    func dryRun(
        yaml: String,
        context: KubernetesContextProfile,
        namespace: String?
    ) async -> KubernetesApplyResult

    func apply(
        yaml: String,
        context: KubernetesContextProfile,
        namespace: String?
    ) async -> KubernetesApplyResult
}

public final class KubernetesYAMLApplier: KubernetesYAMLApplying {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        timeout: TimeInterval = 15
    ) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func dryRun(
        yaml: String,
        context: KubernetesContextProfile,
        namespace: String?
    ) async -> KubernetesApplyResult {
        await execute(yaml: yaml, context: context, namespace: namespace, isDryRun: true)
    }

    public func apply(
        yaml: String,
        context: KubernetesContextProfile,
        namespace: String?
    ) async -> KubernetesApplyResult {
        await execute(yaml: yaml, context: context, namespace: namespace, isDryRun: false)
    }

    private func execute(
        yaml: String,
        context: KubernetesContextProfile,
        namespace: String?,
        isDryRun: Bool
    ) async -> KubernetesApplyResult {
        guard let data = yaml.data(using: .utf8), !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return KubernetesApplyResult(
                success: false,
                isDryRun: isDryRun,
                message: "Validation failed",
                errorDetails: "YAML content is empty."
            )
        }

        var args = context.kubeconfigArguments + ["apply"]
        if isDryRun {
            args.append("--dry-run=server")
        }
        args.append(contentsOf: ["-f", "-"])

        if let namespace = namespace, !namespace.isEmpty, namespace != "-" {
            args += ["--namespace", namespace]
        }

        do {
            var command = try kubectl.inspectionCommand(
                context: context.contextName,
                arguments: args
            )
            command.stdinData = data
            command.environmentOverrides = context.kubeconfigEnvironment

            let result = try await kubectl.run(command, timeout: timeout)
            let trimmedOut = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedErr = KubernetesDiagnosticClassifier.sanitize(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)

            if result.exitCode == 0 {
                return KubernetesApplyResult(
                    success: true,
                    isDryRun: isDryRun,
                    message: isDryRun ? "Dry-run validation passed" : "Resource applied successfully",
                    errorDetails: nil,
                    stdout: trimmedOut,
                    appliedYAML: isDryRun ? nil : yaml
                )
            } else {
                let errorMsg = !trimmedErr.isEmpty ? trimmedErr : (!trimmedOut.isEmpty ? trimmedOut : "Kubectl exited with code \(result.exitCode)")
                return KubernetesApplyResult(
                    success: false,
                    isDryRun: isDryRun,
                    message: isDryRun ? "Server dry-run rejected changes" : "Apply failed",
                    errorDetails: errorMsg,
                    stdout: trimmedOut,
                    appliedYAML: nil
                )
            }
        } catch {
            return KubernetesApplyResult(
                success: false,
                isDryRun: isDryRun,
                message: isDryRun ? "Dry-run execution error" : "Apply execution error",
                errorDetails: error.localizedDescription
            )
        }
    }
}
