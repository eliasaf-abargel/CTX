import Foundation

/// Fetches one resource kind's rows for a context+namespace, always live — caching,
/// staleness, and deduplication are the `ResourceRefreshCoordinator`'s job, not this
/// type's. A reader-level cache used to exist here too; it was never actually able
/// to serve a hit once the coordinator (or the view model before it) always called
/// through with a live-fetch decision already made, so it was dead weight kept
/// "just in case" — removed rather than left as a second, silently-bypassed cache.
public protocol KubernetesResourceReading: Sendable {
    func list(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection) async -> KubernetesResourceList
}

public final class KubernetesResourceReader: KubernetesResourceReading {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let defaultTimeout: TimeInterval
    private let heavyTimeout: TimeInterval

    public init(
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        defaultTimeout: TimeInterval = 12,
        heavyTimeout: TimeInterval = 20
    ) {
        self.kubectl = kubectl
        self.defaultTimeout = defaultTimeout
        self.heavyTimeout = heavyTimeout
    }

    public func list(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection) async -> KubernetesResourceList {
        let namespace = effectiveNamespace(kind: kind, namespace: namespace)
        let started = Date()
        do {
            let commandArguments = arguments(kind: kind, context: context, namespace: namespace)
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: commandArguments)
            command.environmentOverrides = kubeconfigEnvironment(context)
            let timeout = timeout(for: kind, namespace: namespace)
            let result = try await kubectl.run(command, timeout: timeout)
            let subprocessDurationMs = durationMilliseconds(since: started)

            // A cancelled Task's underlying process may still have exited normally
            // (cooperative cancellation isn't instant) — that must never be logged
            // or classified as a timeout or a generic error. The caller (coordinator/
            // view model) already discards a cancelled result before it can reach
            // the UI; this only makes the *diagnostic log* honest about what
            // actually happened, using the outcome format's existing `.cancelled`
            // case rather than the generic `.error`.
            if Task.isCancelled {
                logCall(kind: kind, context: context, namespace: namespace, durationMilliseconds: subprocessDurationMs, outcome: .cancelled)
                return failed(kind: kind, context: context, category: .unknown, message: "cancelled", started: started)
            }

            let category = KubernetesDiagnosticClassifier.category(from: result)
            let parseStarted = Date()
            let parsed = KubernetesResourceParser.parse(kind: kind, stdout: result.stdout)
            let parseDurationMs = durationMilliseconds(since: parseStarted)
            let effectiveCategory: KubernetesDiagnosticCategory
            if kind == .secretMetadata {
                effectiveCategory = category
            } else if parsed != nil {
                effectiveCategory = .success
            } else if category == .success {
                // kubectl exited fine but stdout didn't parse — never call this
                // "success" (would silently show as "0 items found") or "timeout"
                // (it manifestly wasn't one); `.unknown` is the honest category.
                effectiveCategory = .unknown
            } else {
                effectiveCategory = category
            }
            let diagnostic = diagnostic(kind: kind, context: context, result: result, category: effectiveCategory, timeout: timeout, started: started)
            logCall(kind: kind, context: context, namespace: namespace, durationMilliseconds: subprocessDurationMs, outcome: result.timedOut ? .timeout : (effectiveCategory == .success ? .success : .error))

            if kind == .nodes, effectiveCategory != .success {
                logNodesTimeoutDiagnosis(
                    context: context,
                    commandArguments: commandArguments,
                    timeout: timeout,
                    subprocessDurationMs: subprocessDurationMs,
                    parseDurationMs: parseDurationMs,
                    category: effectiveCategory,
                    timedOut: result.timedOut,
                    stderrSummary: diagnostic.stderrSummary
                )
            }

            guard effectiveCategory == .success, var parsed else {
                return KubernetesResourceList(kind: kind, columns: columns(for: kind), rows: [], status: KubernetesDiagnosticClassifier.status(from: effectiveCategory), diagnostic: diagnostic)
            }
            parsed = attachReferences(to: parsed, context: context, namespace: namespace)
            parsed.diagnostic = diagnostic
            parsed.loadedAt = Date()
            return parsed
        } catch KubectlRunnerError.kubectlNotFound {
            logCall(kind: kind, context: context, namespace: namespace, durationMilliseconds: durationMilliseconds(since: started), outcome: .error)
            return failed(kind: kind, context: context, category: .kubectlMissing, message: "kubectl was not found", started: started)
        } catch {
            logCall(kind: kind, context: context, namespace: namespace, durationMilliseconds: durationMilliseconds(since: started), outcome: .error)
            return failed(kind: kind, context: context, category: .unknown, message: error.localizedDescription, started: started)
        }
    }

    /// DEBUG-only, Nodes-only, and only on a non-success outcome — a live-debug
    /// aid for "why did Nodes just fail/time out," not a routine log line. Prints
    /// the exact copyable command (so the same read can be run by hand in
    /// Terminal, e.g. with a longer `--request-timeout` to see whether that's
    /// what's actually needed), the measured subprocess and JSON-parsing
    /// durations separately, the sanitized stderr category, and which of the
    /// four candidate explanations (CTX scheduling / kubectl-auth / cluster-API /
    /// RBAC) fit. A raw `.timeout` is structurally indistinguishable — from
    /// outside the `kubectl` process — between "CTX's own timeout is too tight"
    /// and "the API/auth plugin is just slow that day," so both are listed as
    /// candidates rather than one being guessed.
    private func logNodesTimeoutDiagnosis(
        context: KubernetesContextProfile,
        commandArguments: [String],
        timeout: TimeInterval,
        subprocessDurationMs: Int,
        parseDurationMs: Int,
        category: KubernetesDiagnosticCategory,
        timedOut: Bool,
        stderrSummary: String
    ) {
#if DEBUG
        let execPlugin = detectExecPlugin(context: context)
        let buckets = KubernetesTimeoutBucket.candidates(category: category, hasExecPlugin: execPlugin.hasExecPlugin)
        let serverIsLocal = isLocalServer(context.clusterMetadata.serverURL)
        let timeoutMarginMs = Int(timeout * 1000) - subprocessDurationMs
        let copyableCommand = (["kubectl"] + commandArguments).map(shellQuoted).joined(separator: " ")

        print("""
        [CTX nodes-debug] Nodes did not return success — live diagnosis:
          exact command       : \(copyableCommand)
          configured timeout  : \(Int(timeout))s
          subprocess duration : \(subprocessDurationMs)ms (margin to timeout: \(timeoutMarginMs)ms)
          JSON parse duration : \(parseDurationMs)ms
          timed out           : \(timedOut)
          stderr category     : \(category.rawValue) — \(stderrSummary)
          exec auth plugin    : \(execPlugin.hasExecPlugin ? (execPlugin.command ?? "yes (name unknown)") : "none detected")
          server looks local  : \(serverIsLocal) (Rancher Desktop / kind / local proxy signature)
          candidate cause(s)  : \(buckets.map(\.rawValue).joined(separator: "; "))
          to test manually    : run the exact command above in Terminal, try a longer --request-timeout, and compare
        """)
#endif
    }

    private func detectExecPlugin(context: KubernetesContextProfile) -> KubeConfigAuthPluginDetector.Result {
        let path = context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return KubeConfigAuthPluginDetector.Result(hasExecPlugin: false, command: nil)
        }
        return KubeConfigAuthPluginDetector.detect(in: text, userName: context.userName)
    }

    private func isLocalServer(_ serverURL: String) -> Bool {
        serverURL.contains("127.0.0.1") || serverURL.contains("localhost") || serverURL.contains("0.0.0.0")
    }

    private func shellQuoted(_ argument: String) -> String {
        guard argument.contains(where: { " \t\"'$`\\".contains($0) }) else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func logCall(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection, durationMilliseconds: Int, outcome: CTXPerfLog.Outcome) {
        CTXPerfLog.log(
            step: "kubectl_command",
            contextID: context.id,
            namespace: kind.isClusterScoped ? "cluster" : namespace.storageValue,
            kind: kind.rawValue,
            cache: .none,
            durationMs: durationMilliseconds,
            outcome: outcome
        )
    }

    private func durationMilliseconds(since started: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(started) * 1000))
    }

    private func arguments(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection) -> [String] {
        var args = kubeconfigArguments(context) + ["get", kind.kubectlResource]
        if !kind.isClusterScoped {
            args += namespace.commandArguments
        }
        if kind == .secretMetadata {
            return args + ["--request-timeout=\(Int(timeout(for: kind, namespace: namespace)))s", "--no-headers"]
        }
        return args + ["--request-timeout=\(Int(timeout(for: kind, namespace: namespace)))s", "--output=json"]
    }

    private func timeout(for kind: KubernetesResourceKind, namespace: KubernetesNamespaceSelection) -> TimeInterval {
        if (kind == .pods || kind == .events) && namespace == .allNamespaces {
            return heavyTimeout
        }
        return defaultTimeout
    }

    private func effectiveNamespace(kind: KubernetesResourceKind, namespace: KubernetesNamespaceSelection) -> KubernetesNamespaceSelection {
        kind.isClusterScoped ? .allNamespaces : namespace
    }

    private func kubeconfigArguments(_ context: KubernetesContextProfile) -> [String] {
        context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--kubeconfig", context.kubeconfigPath]
    }

    private func kubeconfigEnvironment(_ context: KubernetesContextProfile) -> [String: String] {
        let path = context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? [:] : ["KUBECONFIG": path]
    }

    private func diagnostic(kind: KubernetesResourceKind, context: KubernetesContextProfile, result: KubectlResult, category: KubernetesDiagnosticCategory, timeout: TimeInterval, started: Date) -> KubernetesCommandDiagnostic {
        KubernetesCommandDiagnostic(
            commandKind: kind.title,
            contextName: context.contextName,
            kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
            exitCode: result.exitCode,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            category: category,
            stderrSummary: diagnosticSummary(result: result, category: category, timeout: timeout)
        )
    }

    private func diagnosticSummary(result: KubectlResult, category: KubernetesDiagnosticCategory, timeout: TimeInterval) -> String {
        let stderr = KubernetesDiagnosticClassifier.sanitize(result.stderr)
        if category == .success {
            return "timeout=\(Int(timeout))s read completed"
        }
        if !stderr.isEmpty {
            return "timeout=\(Int(timeout))s \(stderr)"
        }
        return "timeout=\(Int(timeout))s \(category.presentationSummary)"
    }

    private func failed(kind: KubernetesResourceKind, context: KubernetesContextProfile, category: KubernetesDiagnosticCategory, message: String, started: Date) -> KubernetesResourceList {
        let diag = KubernetesCommandDiagnostic(commandKind: kind.title, contextName: context.contextName, kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath), exitCode: nil, durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)), category: category, stderrSummary: KubernetesDiagnosticClassifier.sanitize(message))
        return KubernetesResourceList(kind: kind, columns: columns(for: kind), rows: [], status: KubernetesDiagnosticClassifier.status(from: category), diagnostic: diag)
    }

    private func attachReferences(to list: KubernetesResourceList, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection) -> KubernetesResourceList {
        var list = list
        list.rows = list.rows.map { row in
            var row = row
            row.ref = KubernetesResourceRef(context: context, kind: list.kind, namespace: namespaceName(for: row, kind: list.kind, fallback: namespace), name: row.name)
            return row
        }
        return list
    }

    private func namespaceName(for row: KubernetesResourceRow, kind: KubernetesResourceKind, fallback: KubernetesNamespaceSelection) -> String? {
        guard !kind.isClusterScoped else { return nil }
        if let namespace = row.namespace { return namespace }
        switch fallback {
        case .defaultNamespace: return "default"
        case .namespace(let name): return name
        case .allNamespaces: return nil
        }
    }

    private func columns(for kind: KubernetesResourceKind) -> [String] {
        switch kind {
        case .namespaces: ["Name", "Status", "Age", "Labels"]
        case .nodes: ["Name", "Ready", "Roles", "Version", "Age", "IP"]
        case .workloads: ["Namespace", "Kind", "Name", "Ready", "Available", "Age"]
        case .pods: ["Namespace", "Name", "Status", "Ready", "Restarts", "Age", "Node"]
        case .services: ["Namespace", "Name", "Type", "Cluster IP", "External", "Ports", "Age"]
        case .ingress: ["Namespace", "Name", "Class", "Hosts", "TLS", "Address", "Age"]
        case .configMaps: ["Namespace", "Name", "Keys", "Age"]
        case .secretMetadata: ["Namespace", "Name", "Type", "Keys", "Age"]
        case .events: ["Namespace", "Object", "Type", "Reason", "Message", "Last", "Count"]
        }
    }
}
