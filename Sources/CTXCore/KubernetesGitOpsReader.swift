import Foundation

/// Which GitOps controllers a cluster actually has installed, and what they report.
public struct GitOpsReadResult: Sendable {
    public var items: [GitOpsApplicationItem]
    /// Controllers whose CRDs exist on this cluster. Empty means neither ArgoCD nor
    /// Flux is installed — a normal state that gets its own empty state, not an error.
    public var installedControllers: [String]
    public var status: KubernetesCheckStatus
    public var diagnostic: KubernetesCommandDiagnostic?

    public init(
        items: [GitOpsApplicationItem],
        installedControllers: [String],
        status: KubernetesCheckStatus,
        diagnostic: KubernetesCommandDiagnostic? = nil
    ) {
        self.items = items
        self.installedControllers = installedControllers
        self.status = status
        self.diagnostic = diagnostic
    }
}

public protocol KubernetesGitOpsReading: Sendable {
    func applications(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection
    ) async -> GitOpsReadResult
}

/// Reads real ArgoCD `Application` and Flux `Kustomization`/`HelmRelease` custom
/// resources.
///
/// Each CRD is read separately rather than as one comma-separated `kubectl get`,
/// because kubectl fails the *whole* command when any one resource type is unknown —
/// which would mean a cluster running ArgoCD but not Flux showed nothing at all.
/// A missing CRD here is simply "that controller isn't installed".
public final class KubernetesGitOpsReader: KubernetesGitOpsReading {
    private struct Source {
        let controller: String
        let resource: String
        let parse: ([[String: Any]]) -> [GitOpsApplicationItem]
    }

    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        timeout: TimeInterval = 15
    ) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    private static let sources: [Source] = [
        Source(
            controller: "ArgoCD",
            resource: "applications.argoproj.io",
            parse: KubernetesGitOpsService.parseArgoCDApplications
        ),
        Source(
            controller: "Flux CD",
            resource: "kustomizations.kustomize.toolkit.fluxcd.io",
            parse: KubernetesGitOpsService.parseFluxKustomizations
        ),
        Source(
            controller: "Flux CD",
            resource: "helmreleases.helm.toolkit.fluxcd.io",
            parse: KubernetesGitOpsService.parseFluxHelmReleases
        )
    ]

    /// GitOps applications are read cluster-wide, never scoped to the workspace's
    /// selected namespace.
    ///
    /// The controller resources live where the *controller* is installed — ArgoCD
    /// `Application` objects sit in the `argocd` namespace, Flux resources in
    /// `flux-system` — while the workloads they deliver land in entirely different
    /// namespaces. Scoping this read to the selected namespace therefore returned
    /// nothing for every namespace except the controller's own, and the screen
    /// truthfully but uselessly reported "installed, but no applications here".
    /// Delivery is a cluster-level concern, so it is read like one.
    public func applications(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection
    ) async -> GitOpsReadResult {
        // Read the three resource types concurrently — serially this cost three
        // round trips to the API server before anything appeared on screen.
        let outcomes = await withTaskGroup(of: (Int, Source, ReadOutcome).self) { group in
            for (index, source) in Self.sources.enumerated() {
                group.addTask { [self] in
                    (index, source, await read(source: source, context: context))
                }
            }
            var collected: [(Int, Source, ReadOutcome)] = []
            for await entry in group { collected.append(entry) }
            return collected.sorted { $0.0 < $1.0 }
        }

        var items: [GitOpsApplicationItem] = []
        var installed: Set<String> = []
        var failures: [KubernetesCommandDiagnostic] = []
        var sawAnyResponse = false

        for (_, source, outcome) in outcomes {
            switch outcome {
            case .notInstalled:
                sawAnyResponse = true
            case .success(let parsed):
                sawAnyResponse = true
                installed.insert(source.controller)
                items.append(contentsOf: parsed)
            case .failure(let diagnostic):
                failures.append(diagnostic)
            }
        }

        // Every read failed for a reason other than a missing CRD — that's a real
        // cluster/auth problem and must be surfaced, not shown as "no applications".
        guard sawAnyResponse else {
            return GitOpsReadResult(
                items: [],
                installedControllers: [],
                status: failures.first.map { KubernetesDiagnosticClassifier.status(from: $0.category) } ?? .notChecked,
                diagnostic: failures.first
            )
        }

        items.sort { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
        return GitOpsReadResult(
            items: items,
            installedControllers: installed.sorted(),
            status: .reachable,
            // A partial failure — say ArgoCD readable but Flux forbidden — keeps the
            // apps that *were* readable on screen while still reporting what was
            // missed, instead of silently showing an incomplete list as complete.
            diagnostic: failures.first
        )
    }

    private enum ReadOutcome {
        case success([GitOpsApplicationItem])
        case notInstalled
        case failure(KubernetesCommandDiagnostic)
    }

    private func read(
        source: Source,
        context: KubernetesContextProfile
    ) async -> ReadOutcome {
        let started = Date()
        var arguments = context.kubeconfigArguments + ["get", source.resource]
        arguments += ["--all-namespaces"]
        arguments += ["--request-timeout=\(Int(timeout))s", "--output=json", "--ignore-not-found"]

        do {
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: arguments)
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)

            if result.exitCode != 0 {
                if Self.indicatesMissingCRD(result.stderr) {
                    return .notInstalled
                }
                return .failure(KubernetesCommandDiagnostic(
                    kind: "GitOps \(source.controller)", context: context, result: result,
                    category: KubernetesDiagnosticClassifier.category(from: result), startedAt: started
                ))
            }

            // `--ignore-not-found` yields empty stdout when the type exists but has
            // no objects; that is an installed controller with zero applications.
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .success([]) }

            guard
                let data = trimmed.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rawItems = root["items"] as? [[String: Any]]
            else {
                return .failure(KubernetesCommandDiagnostic(
                    kind: "GitOps \(source.controller)", context: context, result: result,
                    category: .unknown, startedAt: started
                ))
            }
            return .success(source.parse(rawItems))
        } catch KubectlRunnerError.kubectlNotFound {
            return .failure(KubernetesCommandDiagnostic(
                kind: "GitOps \(source.controller)", context: context,
                category: .kubectlMissing, message: "kubectl was not found", startedAt: started
            ))
        } catch {
            return .failure(KubernetesCommandDiagnostic(
                kind: "GitOps \(source.controller)", context: context,
                category: .unknown, message: error.localizedDescription, startedAt: started
            ))
        }
    }

    /// kubectl's wording for "this CRD isn't registered on the cluster". Distinct
    /// from RBAC denial, which must stay a real, visible failure.
    public static func indicatesMissingCRD(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("the server doesn't have a resource type")
            || lowered.contains("the server could not find the requested resource")
            || lowered.contains("no matches for kind")
            || lowered.contains("unable to recognize")
    }



}
