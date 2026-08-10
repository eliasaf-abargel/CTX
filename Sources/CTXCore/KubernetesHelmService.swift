import Foundation

public struct HelmReleaseItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var chart: String
    public var appVersion: String
    public var revision: Int
    public var status: String
    public var updated: String

    public init(
        namespace: String,
        name: String,
        chart: String,
        appVersion: String,
        revision: Int,
        status: String,
        updated: String
    ) {
        self.namespace = namespace
        self.name = name
        self.chart = chart
        self.appVersion = appVersion
        self.revision = revision
        self.status = status
        self.updated = updated
    }
}

public struct HelmReadResult: Sendable {
    public enum SourceOfTruth: String, Sendable {
        /// `helm list` — every column is real, including chart and app version.
        case helmCLI
        /// Release metadata read off the storage Secrets' labels. Real name,
        /// revision, status and age; chart and app version live only inside the
        /// Secret's payload, which CTX does not read.
        case releaseSecretLabels
    }

    public var items: [HelmReleaseItem]
    public var source: SourceOfTruth
    public var status: KubernetesCheckStatus
    public var diagnostic: KubernetesCommandDiagnostic?

    public init(
        items: [HelmReleaseItem],
        source: SourceOfTruth,
        status: KubernetesCheckStatus,
        diagnostic: KubernetesCommandDiagnostic? = nil
    ) {
        self.items = items
        self.source = source
        self.status = status
        self.diagnostic = diagnostic
    }
}

public protocol KubernetesHelmReading: Sendable {
    func releases(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection
    ) async -> HelmReadResult
}

/// Reads real Helm releases.
///
/// Preferred path is `helm list -o json`, which reports chart, app version, status,
/// revision and update time exactly as Helm itself sees them. When the `helm` binary
/// isn't installed, releases are still discovered from the labels Helm writes on its
/// own storage Secrets (`owner=helm`), which carry the release name, revision and
/// status. The Secret *payload* — where chart and app version live — is deliberately
/// never read: it is a secret value, and CTX's safety model keeps Secrets
/// metadata-only. Those two columns report unknown rather than a guess.
public final class KubernetesHelmReader: KubernetesHelmReading {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let resolveBinary: @Sendable (String) -> String?
    private let timeout: TimeInterval

    public init(
        kubectl: (any KubectlRunning & KubectlCommandBuilding)? = nil,
        resolveBinary: (@Sendable (String) -> String?)? = nil,
        timeout: TimeInterval = 20
    ) {
        let runner = kubectl ?? KubectlRunner()
        self.kubectl = runner
        if let resolveBinary {
            self.resolveBinary = resolveBinary
        } else {
            // Only a real `KubectlRunner` knows the CLI search path; an injected
            // test double resolves nothing, which exercises the Secret-label path.
            let pathResolver = runner as? KubectlRunner
            self.resolveBinary = { pathResolver?.resolve($0) }
        }
        self.timeout = timeout
    }

    public func releases(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection
    ) async -> HelmReadResult {
        if let helmPath = resolveBinary("helm") {
            let result = await readViaHelmCLI(helmPath: helmPath, context: context, namespace: namespace)
            // Only fall back when helm itself couldn't answer. A successful run that
            // found nothing means there are genuinely no releases in scope.
            if result.status == .reachable {
                return result
            }
        }
        return await readViaReleaseSecrets(context: context, namespace: namespace)
    }

    // MARK: - helm list

    private func readViaHelmCLI(
        helmPath: String,
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection
    ) async -> HelmReadResult {
        let started = Date()
        // `helm list` without `--all` applies a state filter that hides exactly the
        // releases worth looking at: anything stuck in pending-install,
        // pending-upgrade or pending-rollback. With `--all` every release is
        // returned and the Status column reports its real state.
        var arguments = ["list", "--all", "--output", "json", "--kube-context", context.contextName]
        switch namespace {
        case .allNamespaces: arguments.append("--all-namespaces")
        case .defaultNamespace: arguments.append(contentsOf: ["--namespace", "default"])
        case .namespace(let name): arguments.append(contentsOf: ["--namespace", name])
        }
        let kubeconfig = context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kubeconfig.isEmpty {
            arguments.append(contentsOf: ["--kubeconfig", kubeconfig])
        }

        let command = KubectlCommand(
            executablePath: helmPath,
            arguments: arguments,
            environmentOverrides: kubeconfig.isEmpty ? [:] : ["KUBECONFIG": kubeconfig]
        )

        do {
            let result = try await kubectl.run(command, timeout: timeout)
            guard result.exitCode == 0 else {
                return HelmReadResult(
                    items: [],
                    source: .helmCLI,
                    status: KubernetesDiagnosticClassifier.status(from: KubernetesDiagnosticClassifier.category(from: result)),
                    diagnostic: KubernetesCommandDiagnostic(
                        kind: "Helm releases", context: context, result: result,
                        category: KubernetesDiagnosticClassifier.category(from: result), startedAt: started
                    )
                )
            }
            return HelmReadResult(
                items: Self.parseHelmListJSON(result.stdout),
                source: .helmCLI,
                status: .reachable
            )
        } catch {
            return HelmReadResult(items: [], source: .helmCLI, status: .unreachable, diagnostic: nil)
        }
    }

    public static func parseHelmListJSON(_ stdout: String) -> [HelmReleaseItem] {
        guard
            let data = stdout.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let revisionRaw = entry["revision"]
            let revision = (revisionRaw as? Int) ?? Int((revisionRaw as? String) ?? "") ?? 0
            return HelmReleaseItem(
                namespace: (entry["namespace"] as? String) ?? KubernetesGitOpsService.unknownValue,
                name: name,
                chart: (entry["chart"] as? String) ?? KubernetesGitOpsService.unknownValue,
                appVersion: (entry["app_version"] as? String) ?? KubernetesGitOpsService.unknownValue,
                revision: revision,
                status: (entry["status"] as? String) ?? KubernetesGitOpsService.unknownValue,
                updated: KubernetesGitOpsService.relativeAge(from: normalizedHelmTimestamp(entry["updated"] as? String))
            )
        }
        .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// `helm list` prints Go's default time layout ("2024-01-02 15:04:05.123 +0000 UTC"),
    /// not ISO 8601. Reduce it to something the ISO parser accepts.
    static func normalizedHelmTimestamp(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: " ")
        guard parts.count >= 3 else { return raw }
        let day = parts[0]
        let time = parts[1].split(separator: ".").first ?? parts[1]
        let zone = parts[2] == "+0000" ? "Z" : String(parts[2])
        return "\(day)T\(time)\(zone)"
    }

    // MARK: - Release-secret labels

    private func readViaReleaseSecrets(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection
    ) async -> HelmReadResult {
        let started = Date()
        var arguments = context.kubeconfigArguments + ["get", "secrets", "--selector", "owner=helm"]
        arguments += namespace.commandArguments
        // Only labels and creation time are requested. `.data` is never selected, so
        // no secret value is fetched, logged or cached.
        arguments += [
            "--output=custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.labels.name,REVISION:.metadata.labels.version,STATUS:.metadata.labels.status,UPDATED:.metadata.creationTimestamp",
            "--no-headers",
            "--request-timeout=\(Int(timeout))s"
        ]

        do {
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: arguments)
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            guard result.exitCode == 0 else {
                return HelmReadResult(
                    items: [],
                    source: .releaseSecretLabels,
                    status: KubernetesDiagnosticClassifier.status(from: KubernetesDiagnosticClassifier.category(from: result)),
                    diagnostic: KubernetesCommandDiagnostic(
                        kind: "Helm releases", context: context, result: result,
                        category: KubernetesDiagnosticClassifier.category(from: result), startedAt: started
                    )
                )
            }
            return HelmReadResult(
                items: Self.parseReleaseSecretLabels(result.stdout),
                source: .releaseSecretLabels,
                status: .reachable
            )
        } catch {
            return HelmReadResult(items: [], source: .releaseSecretLabels, status: .unreachable, diagnostic: nil)
        }
    }

    /// Helm keeps one Secret per revision. Only the highest revision per release is
    /// the current one, so earlier revisions are collapsed away rather than listed
    /// as separate releases.
    public static func parseReleaseSecretLabels(_ stdout: String) -> [HelmReleaseItem] {
        var latest: [String: HelmReleaseItem] = [:]

        for line in stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 5 else { continue }
            let namespace = fields[0]
            let name = fields[1]
            guard name != "<none>", !name.isEmpty else { continue }
            let revision = Int(fields[2]) ?? 0
            let status = fields[3] == "<none>" ? KubernetesGitOpsService.unknownValue : fields[3]
            let updated = fields[4] == "<none>" ? nil : fields[4]

            let key = "\(namespace)/\(name)"
            if let existing = latest[key], existing.revision >= revision { continue }
            latest[key] = HelmReleaseItem(
                namespace: namespace,
                name: name,
                // Chart and app version live inside the Secret payload, which CTX
                // does not read. Reported as unknown rather than guessed.
                chart: KubernetesGitOpsService.unknownValue,
                appVersion: KubernetesGitOpsService.unknownValue,
                revision: revision,
                status: status,
                updated: KubernetesGitOpsService.relativeAge(from: updated)
            )
        }

        return latest.values.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    // MARK: - Shared



}
