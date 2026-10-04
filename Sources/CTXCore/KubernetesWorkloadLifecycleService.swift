import Foundation

/// The controller kinds `kubectl rollout`/`kubectl scale` actually operate on.
/// Deliberately narrower than every kind the Workloads table lists — a bare
/// Pod has no rollout history to restart or undo, and Jobs/CronJobs have
/// entirely different restart semantics (a new Job run, not an in-place
/// restart of existing pods).
public enum KubernetesWorkloadControllerKind: String, Sendable {
    case deployment
    case statefulSet
    case daemonSet

    /// The exact resource-type string `kubectl rollout`/`kubectl scale` expect.
    public var kubectlResource: String {
        switch self {
        case .deployment: "deployment"
        case .statefulSet: "statefulset"
        case .daemonSet: "daemonset"
        }
    }

    /// DaemonSets run exactly one pod per eligible node — there is no
    /// replica count to scale to zero.
    public var supportsScale: Bool { self != .daemonSet }

    /// Matches the `"Kind"` cell the Workloads table already reports
    /// (`workloadRow` in KubernetesResourceParser), so callers don't need a
    /// second mapping of the same three strings.
    public init?(rowKind: String) {
        switch rowKind {
        case "Deployment": self = .deployment
        case "StatefulSet": self = .statefulSet
        case "DaemonSet": self = .daemonSet
        default: return nil
        }
    }
}

/// A GitOps controller already reconciling this exact object — detected from
/// the labels/annotations ArgoCD and Flux both stamp onto everything they
/// manage, read live off the object rather than guessed from the presence of
/// a GitOps Application elsewhere in the cluster. `nil` means those specific
/// markers weren't found, not a guarantee nothing else manages this object.
public struct KubernetesGitOpsOwnership: Equatable, Sendable {
    public let controller: String
    public let applicationName: String?
}

/// One entry from `kubectl rollout history`. `image` is filled in only for
/// the revisions actually inspected (`rolloutRevisions` looks up the two
/// most recent) — a full history can be long, and every entry costs one more
/// `kubectl` call to resolve.
public struct KubernetesRolloutRevision: Equatable, Sendable, Identifiable {
    public var id: Int { revision }
    public let revision: Int
    public let changeCause: String?
    public let image: String?
}

public struct KubernetesLifecycleActionResult: Equatable, Sendable {
    public let success: Bool
    public let message: String
    public let errorDetails: String?
    public let stdout: String

    public init(success: Bool, message: String, errorDetails: String? = nil, stdout: String = "") {
        self.success = success
        self.message = message
        self.errorDetails = errorDetails
        self.stdout = stdout
    }
}

public protocol KubernetesWorkloadLifecycleManaging: Sendable {
    func restart(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> KubernetesLifecycleActionResult

    func scale(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile,
        replicas: Int
    ) async -> KubernetesLifecycleActionResult

    func rollbackToPreviousRevision(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> KubernetesLifecycleActionResult

    /// What a person needs to know *before* confirming any of the three
    /// actions above: is a GitOps controller already reconciling this object,
    /// and — for Rollback specifically — which revision it would land on and
    /// what image that revision actually runs.
    func detectGitOpsOwnership(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> KubernetesGitOpsOwnership?

    /// The current and previous revision, with each one's image resolved —
    /// not just revision numbers, which `CHANGE-CAUSE` alone rarely explains
    /// anything useful (it's `<none>` unless something set it at apply time).
    func recentRolloutRevisions(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> [KubernetesRolloutRevision]
}

/// Three well-scoped, fully-reversible `kubectl` verbs — nothing here patches
/// arbitrary fields or deletes an object. `rollout restart` and `rollout undo`
/// are exactly what Kubernetes itself already offers for "restart these pods"
/// and "go back to what was running before"; `scale --replicas` is the
/// standard way to stop and resume a Deployment/StatefulSet without deleting
/// its definition.
public final class KubernetesWorkloadLifecycleService: KubernetesWorkloadLifecycleManaging {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        timeout: TimeInterval = 15
    ) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func restart(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> KubernetesLifecycleActionResult {
        await run(
            ["rollout", "restart", "\(kind.kubectlResource)/\(name)"],
            namespace: namespace,
            context: context,
            successMessage: "Restart triggered",
            failureMessage: "Restart failed"
        )
    }

    public func scale(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile,
        replicas: Int
    ) async -> KubernetesLifecycleActionResult {
        guard kind.supportsScale else {
            return KubernetesLifecycleActionResult(
                success: false,
                message: "Not supported",
                errorDetails: "A DaemonSet runs one pod per node — it has no replica count to scale."
            )
        }
        guard replicas >= 0 else {
            return KubernetesLifecycleActionResult(success: false, message: "Invalid replica count", errorDetails: "Replica count cannot be negative.")
        }
        return await run(
            ["scale", "\(kind.kubectlResource)/\(name)", "--replicas=\(replicas)"],
            namespace: namespace,
            context: context,
            successMessage: replicas == 0 ? "Stopped" : "Scaled to \(replicas)",
            failureMessage: "Scale failed"
        )
    }

    public func rollbackToPreviousRevision(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> KubernetesLifecycleActionResult {
        await run(
            ["rollout", "undo", "\(kind.kubectlResource)/\(name)"],
            namespace: namespace,
            context: context,
            successMessage: "Rolled back to the previous revision",
            failureMessage: "Rollback failed"
        )
    }

    public func detectGitOpsOwnership(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> KubernetesGitOpsOwnership? {
        guard let json = await readStdout(
            ["get", "\(kind.kubectlResource)/\(name)", "--namespace", namespace, "--output=json"],
            context: context
        ) else { return nil }
        return Self.parseGitOpsOwnership(fromObjectJSON: json)
    }

    /// Checked in order of specificity: an ArgoCD tracking-id annotation or
    /// its own instance label are unambiguous; the Flux labels are similarly
    /// tool-specific. Deliberately does *not* treat the generic
    /// `app.kubernetes.io/instance` label as evidence — plain Helm sets that
    /// too, and a false "GitOps-managed" warning on an object nothing is
    /// reconciling would just teach people to ignore the real ones.
    public static func parseGitOpsOwnership(fromObjectJSON json: String) -> KubernetesGitOpsOwnership? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any] else { return nil }
        let labels = metadata["labels"] as? [String: String] ?? [:]
        let annotations = metadata["annotations"] as? [String: String] ?? [:]

        if let trackingID = annotations["argocd.argoproj.io/tracking-id"] {
            let appName = trackingID.split(separator: ":").first.map(String.init)
            return KubernetesGitOpsOwnership(controller: "ArgoCD", applicationName: appName)
        }
        if let app = labels["argocd.argoproj.io/instance"] {
            return KubernetesGitOpsOwnership(controller: "ArgoCD", applicationName: app)
        }
        if let name = labels["kustomize.toolkit.fluxcd.io/name"] {
            return KubernetesGitOpsOwnership(controller: "Flux", applicationName: name)
        }
        if let name = labels["helm.toolkit.fluxcd.io/name"] {
            return KubernetesGitOpsOwnership(controller: "Flux", applicationName: name)
        }
        return nil
    }

    public func recentRolloutRevisions(
        kind: KubernetesWorkloadControllerKind,
        name: String,
        namespace: String,
        context: KubernetesContextProfile
    ) async -> [KubernetesRolloutRevision] {
        guard let historyOutput = await readStdout(
            ["rollout", "history", "\(kind.kubectlResource)/\(name)", "--namespace", namespace],
            context: context
        ) else { return [] }

        var revisions = Self.parseRolloutHistory(historyOutput)
        let mostRecent = revisions.suffix(2)
        for entry in mostRecent {
            guard let detail = await readStdout(
                ["rollout", "history", "\(kind.kubectlResource)/\(name)", "--namespace", namespace, "--revision=\(entry.revision)"],
                context: context
            ) else { continue }
            guard let image = Self.parseImage(fromRevisionDetail: detail),
                  let index = revisions.firstIndex(where: { $0.revision == entry.revision }) else { continue }
            revisions[index] = KubernetesRolloutRevision(revision: entry.revision, changeCause: entry.changeCause, image: image)
        }
        return revisions
    }

    /// `kubectl rollout history <kind>/<name>` prints a header line, then
    /// `REVISION  CHANGE-CAUSE` rows — `<none>` unless something recorded a
    /// cause at apply time, which most manifests never do.
    public static func parseRolloutHistory(_ output: String) -> [KubernetesRolloutRevision] {
        var revisions: [KubernetesRolloutRevision] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, let revision = Int(first) else { continue }
            let cause = fields.count > 1 ? fields.dropFirst().joined(separator: " ") : nil
            revisions.append(KubernetesRolloutRevision(revision: revision, changeCause: (cause == "<none>" ? nil : cause), image: nil))
        }
        return revisions
    }

    /// `kubectl rollout history <kind>/<name> --revision=N` prints a Pod
    /// Template description with one `Image:` line per container. Joined
    /// with a comma for the (rare) multi-container case rather than only
    /// ever reporting the first.
    public static func parseImage(fromRevisionDetail output: String) -> String? {
        let images = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Image:") }
            .map { $0.replacingOccurrences(of: "Image:", with: "").trimmingCharacters(in: .whitespaces) }
        return images.isEmpty ? nil : images.joined(separator: ", ")
    }

    private func readStdout(_ arguments: [String], context: KubernetesContextProfile) async -> String? {
        do {
            let args = context.kubeconfigArguments + arguments
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: args)
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            guard result.exitCode == 0 else { return nil }
            return result.stdout
        } catch {
            return nil
        }
    }

    private func run(
        _ verb: [String],
        namespace: String,
        context: KubernetesContextProfile,
        successMessage: String,
        failureMessage: String
    ) async -> KubernetesLifecycleActionResult {
        do {
            var args = context.kubeconfigArguments + verb
            if !namespace.isEmpty {
                args += ["--namespace", namespace]
            }
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: args)
            command.environmentOverrides = context.kubeconfigEnvironment

            let result = try await kubectl.run(command, timeout: timeout)
            let trimmedOut = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedErr = KubernetesDiagnosticClassifier.sanitize(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)

            if result.exitCode == 0 {
                return KubernetesLifecycleActionResult(success: true, message: successMessage, stdout: trimmedOut)
            } else {
                let errorMsg = !trimmedErr.isEmpty ? trimmedErr : (!trimmedOut.isEmpty ? trimmedOut : "Kubectl exited with code \(result.exitCode)")
                return KubernetesLifecycleActionResult(success: false, message: failureMessage, errorDetails: errorMsg, stdout: trimmedOut)
            }
        } catch {
            return KubernetesLifecycleActionResult(success: false, message: failureMessage, errorDetails: error.localizedDescription)
        }
    }
}
