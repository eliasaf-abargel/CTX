import Foundation

/// Turns a Pod's real JSON into the container-level facts the inspector shows.
///
/// This replaces per-name guesswork — the inspector previously produced environment
/// variables, probes and security context by matching the pod's *name* against a
/// hardcoded list, which meant the values on screen had no relationship to the
/// cluster. Everything below is read from the object itself; anything the spec does
/// not declare is reported as absent rather than filled in.
public enum KubernetesWorkloadSpecParser {

    public static func podSpec(fromPodJSON stdout: String) -> PodSpecInsight? {
        guard
            let data = stdout.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return podSpec(fromPodObject: root)
    }

    public static func podSpec(fromPodObject root: [String: Any]) -> PodSpecInsight? {
        guard let spec = root["spec"] as? [String: Any] else { return nil }
        let podSecurity = spec["securityContext"] as? [String: Any] ?? [:]

        let regular = (spec["containers"] as? [[String: Any]] ?? []).map {
            container($0, podSecurity: podSecurity, isInit: false)
        }
        let initContainers = (spec["initContainers"] as? [[String: Any]] ?? []).map {
            container($0, podSecurity: podSecurity, isInit: true)
        }

        return PodSpecInsight(
            containers: initContainers + regular,
            serviceAccount: text(spec["serviceAccountName"] ?? spec["serviceAccount"]),
            nodeName: text(spec["nodeName"]),
            status: .reachable
        )
    }

    // MARK: - Container

    private static func container(
        _ raw: [String: Any],
        podSecurity: [String: Any],
        isInit: Bool
    ) -> ContainerSpecInsight {
        let name = (raw["name"] as? String) ?? KubernetesGitOpsService.unknownValue
        return ContainerSpecInsight(
            name: name,
            image: text(raw["image"]),
            isInitContainer: isInit,
            env: environment(raw, container: name),
            probes: probes(raw, container: name),
            security: security(raw, podSecurity: podSecurity, container: name),
            resources: resources(raw, container: name)
        )
    }

    // MARK: - Environment

    static func environment(_ container: [String: Any], container name: String) -> [EnvVarItem] {
        var items: [EnvVarItem] = []

        // `envFrom` pulls in every key of a ConfigMap or Secret at once. The keys
        // aren't listed in the spec, so the reference itself is what gets reported —
        // and for a Secret, that is all CTX will ever know about it.
        for entry in container["envFrom"] as? [[String: Any]] ?? [] {
            if let secret = entry["secretRef"] as? [String: Any] {
                items.append(EnvVarItem(
                    name: "(all keys)",
                    container: name,
                    source: "Secret \(text(secret["name"]))",
                    isSecret: true
                ))
            } else if let configMap = entry["configMapRef"] as? [String: Any] {
                items.append(EnvVarItem(
                    name: "(all keys)",
                    container: name,
                    source: "ConfigMap \(text(configMap["name"]))"
                ))
            }
        }

        for entry in container["env"] as? [[String: Any]] ?? [] {
            guard let key = entry["name"] as? String else { continue }
            if let literal = entry["value"] as? String {
                items.append(EnvVarItem(name: key, value: literal, container: name))
                continue
            }
            let from = entry["valueFrom"] as? [String: Any] ?? [:]
            if let secret = from["secretKeyRef"] as? [String: Any] {
                // Only the reference. The Secret is never read.
                items.append(EnvVarItem(
                    name: key,
                    container: name,
                    source: "Secret \(text(secret["name"]))/\(text(secret["key"]))",
                    isSecret: true
                ))
            } else if let configMap = from["configMapKeyRef"] as? [String: Any] {
                items.append(EnvVarItem(
                    name: key,
                    container: name,
                    source: "ConfigMap \(text(configMap["name"]))/\(text(configMap["key"]))"
                ))
            } else if let field = from["fieldRef"] as? [String: Any] {
                items.append(EnvVarItem(name: key, container: name, source: "field \(text(field["fieldPath"]))"))
            } else if let resource = from["resourceFieldRef"] as? [String: Any] {
                items.append(EnvVarItem(name: key, container: name, source: "resource \(text(resource["resource"]))"))
            } else {
                items.append(EnvVarItem(name: key, container: name, source: KubernetesGitOpsService.unknownValue))
            }
        }
        return items
    }

    // MARK: - Probes

    static func probes(_ container: [String: Any], container name: String) -> [ProbeInfo] {
        [("Liveness", "livenessProbe"), ("Readiness", "readinessProbe"), ("Startup", "startupProbe")]
            .map { label, key in
                guard let probe = container[key] as? [String: Any] else {
                    // An unset probe is a real, useful finding — a container with no
                    // readiness probe takes traffic before it can serve it.
                    return ProbeInfo(type: label, container: name, isConfigured: false)
                }
                return ProbeInfo(
                    type: label,
                    target: probeTarget(probe),
                    container: name,
                    delaySeconds: number(probe["initialDelaySeconds"]),
                    periodSeconds: number(probe["periodSeconds"]),
                    isConfigured: true
                )
            }
    }

    private static func probeTarget(_ probe: [String: Any]) -> String {
        if let http = probe["httpGet"] as? [String: Any] {
            let scheme = (http["scheme"] as? String)?.uppercased() == "HTTPS" ? "HTTPS" : "HTTP"
            let path = (http["path"] as? String) ?? "/"
            return "\(scheme) GET \(path):\(port(http["port"]))"
        }
        if let tcp = probe["tcpSocket"] as? [String: Any] {
            return "TCP :\(port(tcp["port"]))"
        }
        if let exec = probe["exec"] as? [String: Any] {
            let command = (exec["command"] as? [String] ?? []).joined(separator: " ")
            return command.isEmpty ? "exec" : "exec \(command)"
        }
        if let grpc = probe["grpc"] as? [String: Any] {
            return "gRPC :\(port(grpc["port"]))"
        }
        return KubernetesGitOpsService.unknownValue
    }

    /// A probe port is either a number or a named port from the container spec.
    private static func port(_ raw: Any?) -> String {
        if let number = raw as? Int { return String(number) }
        if let name = raw as? String, !name.isEmpty { return name }
        return KubernetesGitOpsService.unknownValue
    }

    // MARK: - Security context

    static func security(
        _ container: [String: Any],
        podSecurity: [String: Any],
        container name: String
    ) -> SecurityContextAudit {
        let own = container["securityContext"] as? [String: Any] ?? [:]
        // Container-level settings win; anything it leaves unset falls back to the
        // pod-level context. That is how the kubelet resolves it.
        func setting(_ key: String) -> Any? { own[key] ?? podSecurity[key] }

        let runAsUserValue = setting("runAsUser")
        let runAsUser = runAsUserValue.map { String(describing: $0) } ?? KubernetesGitOpsService.unknownValue
        let runAsNonRoot = setting("runAsNonRoot") as? Bool

        // Root is only asserted when something actually says so: UID 0, or an
        // explicit `runAsNonRoot: false`. An unset context is unknown, not "safe".
        let isRoot: Bool
        if let uid = runAsUserValue.flatMap({ Int(String(describing: $0)) }) {
            isRoot = uid == 0
        } else {
            isRoot = runAsNonRoot == false
        }

        let capabilities = own["capabilities"] as? [String: Any] ?? [:]
        return SecurityContextAudit(
            container: name,
            runAsUser: runAsUser,
            isRoot: isRoot,
            isReadOnlyRootFS: (own["readOnlyRootFilesystem"] as? Bool) ?? false,
            isPrivileged: (own["privileged"] as? Bool) ?? false,
            allowPrivilegeEscalation: (setting("allowPrivilegeEscalation") as? Bool) ?? false,
            addedCapabilities: (capabilities["add"] as? [String]) ?? []
        )
    }

    // MARK: - Resources

    static func resources(_ container: [String: Any], container name: String) -> ResourceAllocation {
        let resources = container["resources"] as? [String: Any] ?? [:]
        let requests = resources["requests"] as? [String: Any] ?? [:]
        let limits = resources["limits"] as? [String: Any] ?? [:]
        func quantity(_ source: [String: Any], _ key: String) -> String? {
            guard let raw = source[key] else { return nil }
            let value = String(describing: raw)
            return value.isEmpty ? nil : value
        }
        return ResourceAllocation(
            container: name,
            cpuRequest: quantity(requests, "cpu"),
            cpuLimit: quantity(limits, "cpu"),
            memoryRequest: quantity(requests, "memory"),
            memoryLimit: quantity(limits, "memory")
        )
    }

    // MARK: - Endpoints

    /// Parses a Service's Endpoints object into the addresses actually backing it.
    /// Not-ready addresses are kept and flagged — a Service with zero ready
    /// endpoints is the single most common reason "the service is up but nothing
    /// answers", and hiding them would hide the answer.
    public static func endpoints(fromEndpointsJSON stdout: String) -> [EndpointTarget] {
        guard
            let data = stdout.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let namespace = text((root["metadata"] as? [String: Any])?["namespace"])
        var targets: [EndpointTarget] = []

        for subset in root["subsets"] as? [[String: Any]] ?? [] {
            let ports = (subset["ports"] as? [[String: Any]] ?? []).map { entry -> String in
                let number = entry["port"].map { String(describing: $0) } ?? ""
                let name = entry["name"] as? String
                return name.map { "\(number)/\($0)" } ?? number
            }
            let portLabel = ports.isEmpty ? KubernetesGitOpsService.unknownValue : ports.joined(separator: ", ")

            for (key, ready) in [("addresses", true), ("notReadyAddresses", false)] {
                for address in subset[key] as? [[String: Any]] ?? [] {
                    let ip = text(address["ip"])
                    let targetRef = address["targetRef"] as? [String: Any]
                    let podName = (targetRef?["name"] as? String) ?? ip
                    targets.append(EndpointTarget(
                        name: podName,
                        namespace: (targetRef?["namespace"] as? String) ?? namespace,
                        address: ip,
                        targetPort: portLabel,
                        isHealthy: ready
                    ))
                }
            }
        }
        return targets
    }

    // MARK: - Node capacity

    /// Real `status.capacity` / `status.allocatable` for a node. The gauges used to
    /// be drawn from hardcoded numbers unrelated to the cluster.
    public static func nodeCapacity(fromNodeObject item: [String: Any]) -> (cpu: String, memory: String, pods: String)? {
        guard let status = item["status"] as? [String: Any] else { return nil }
        let allocatable = status["allocatable"] as? [String: Any] ?? [:]
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        func quantity(_ key: String) -> String {
            let raw = allocatable[key] ?? capacity[key]
            return raw.map { String(describing: $0) } ?? KubernetesGitOpsService.unknownValue
        }
        return (quantity("cpu"), quantity("memory"), quantity("pods"))
    }

    // MARK: - Helpers

    private static func text(_ raw: Any?) -> String {
        guard let value = raw as? String, !value.isEmpty else { return KubernetesGitOpsService.unknownValue }
        return value
    }

    private static func number(_ raw: Any?) -> Int {
        (raw as? Int) ?? Int(String(describing: raw ?? "")) ?? 0
    }
}
