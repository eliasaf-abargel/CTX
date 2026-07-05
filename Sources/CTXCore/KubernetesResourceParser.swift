import Foundation

enum KubernetesResourceParser {
    static func parse(kind: KubernetesResourceKind, stdout: String) -> KubernetesResourceList? {
        if kind == .secretMetadata {
            return parseSecretTable(stdout)
        }
        guard let items = jsonItems(stdout) else { return nil }
        switch kind {
        case .namespaces: return list(kind, ["Name", "Status", "Age", "Labels"], items.map(namespaceRow))
        case .nodes: return list(kind, ["Name", "Ready", "Roles", "Version", "Age", "IP"], items.map(nodeRow))
        case .workloads: return list(kind, ["Namespace", "Kind", "Name", "Ready", "Available", "Age"], items.map(workloadRow))
        case .pods: return list(kind, ["Namespace", "Name", "Status", "Ready", "Restarts", "Age", "Node", "Pod IP", "QoS", "Owner", "Workload"], items.map(podRow))
        case .services: return list(kind, ["Namespace", "Name", "Type", "Cluster IP", "External", "Ports", "Age"], items.map(serviceRow))
        case .ingress: return list(kind, ["Namespace", "Name", "Class", "Hosts", "TLS", "Address", "Age"], items.map(ingressRow))
        case .configMaps: return list(kind, ["Namespace", "Name", "Keys", "Age"], items.map(configMapRow))
        case .events: return list(kind, ["Namespace", "Object", "Type", "Reason", "Message", "Last", "Count"], items.map(eventRow).sorted { ($0.sortValue ?? "") > ($1.sortValue ?? "") })
        case .secretMetadata: return nil
        }
    }

    private static func list(_ kind: KubernetesResourceKind, _ columns: [String], _ rows: [KubernetesResourceRow]) -> KubernetesResourceList {
        KubernetesResourceList(kind: kind, columns: columns, rows: rows, status: .reachable)
    }

    private static func jsonItems(_ text: String) -> [[String: Any]]? {
        guard
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["items"] as? [[String: Any]]
    }

    private static func namespaceRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let name = string(metadata["name"])
        let labels = dict(metadata["labels"]).count
        return row(name, ["Name": name, "Status": string(dict(item["status"])["phase"]), "Age": age(metadata), "Labels": String(labels)])
    }

    private static func nodeRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let status = dict(item["status"])
        let ready = (status["conditions"] as? [[String: Any]] ?? []).contains { string($0["type"]) == "Ready" && string($0["status"]) == "True" }
        let addresses = status["addresses"] as? [[String: Any]] ?? []
        let ip = addresses.first { string($0["type"]) == "InternalIP" }.map { string($0["address"]) } ?? ""
        let labels = dict(metadata["labels"])
        let roles = labels.keys.compactMap { key -> String? in
            key.hasPrefix("node-role.kubernetes.io/") ? String(key.dropFirst("node-role.kubernetes.io/".count)) : nil
        }.joined(separator: ", ")
        return row(string(metadata["name"]), [
            "Name": string(metadata["name"]),
            "Ready": ready ? "Ready" : "Not ready",
            "Roles": roles.isEmpty ? "-" : roles,
            "Version": string(dict(status["nodeInfo"])["kubeletVersion"]),
            "Age": age(metadata),
            "IP": ip
        ], warning: !ready)
    }

    private static func workloadRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let status = dict(item["status"])
        let spec = dict(item["spec"])
        let desired = int(spec["replicas"], defaultValue: int(status["desiredNumberScheduled"], defaultValue: 0))
        let ready = int(status["readyReplicas"], defaultValue: int(status["numberReady"], defaultValue: 0))
        // `spec.selector.matchLabels` is the standard Kubernetes field every workload
        // kind here (Deployment/StatefulSet/DaemonSet) uses to own its Pods — reading
        // it generically here means Pod↔Workload discovery never needs a per-kind or
        // per-app special case.
        let selector = encodedLabels(dict(dict(spec["selector"])["matchLabels"]))
        return row(key(metadata), [
            "Namespace": namespace(metadata),
            "Kind": string(item["kind"]),
            "Name": string(metadata["name"]),
            "Ready": "\(ready)/\(desired)",
            "Available": String(int(status["availableReplicas"], defaultValue: int(status["currentNumberScheduled"], defaultValue: 0))),
            "Age": age(metadata),
            "Selector": selector
        ], warning: ready < desired)
    }

    private static func podRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let status = dict(item["status"])
        let containers = status["containerStatuses"] as? [[String: Any]] ?? []
        let ready = containers.filter { ($0["ready"] as? Bool) == true }.count
        let restarts = containers.reduce(0) { $0 + int($1["restartCount"], defaultValue: 0) }
        let phase = string(status["phase"])
        let crashLoop = containers.contains { container in
            let reason = string(dict(dict(container["state"])["waiting"])["reason"]).lowercased()
            return reason.contains("crashloop") || reason.contains("backoff")
        }
        return row(key(metadata), [
            "Namespace": namespace(metadata),
            "Name": string(metadata["name"]),
            "Status": crashLoop ? "CrashLoopBackOff" : phase,
            "Ready": "\(ready)/\(containers.count)",
            "Restarts": String(restarts),
            "Age": age(metadata),
            "Node": string(dict(item["spec"])["nodeName"]),
            "Pod IP": string(status["podIP"]),
            "QoS": string(status["qosClass"]),
            "Owner": ownerChain(metadata),
            "Workload": workloadLabel(metadata),
            "Labels": encodedLabels(dict(metadata["labels"]))
        ], warning: phase != "Running" || crashLoop)
    }

    /// Best-effort "what this pod belongs to" for display only (e.g. a Logs pod
    /// picker) — prefers common app labels, falls back to the owning
    /// controller's kind/name (stripping the ReplicaSet hash suffix so it reads
    /// as the Deployment name), empty if neither is present.
    private static func workloadLabel(_ metadata: [String: Any]) -> String {
        let labels = dict(metadata["labels"])
        if let name = labels["app.kubernetes.io/name"] as? String, !name.isEmpty { return name }
        if let name = labels["app"] as? String, !name.isEmpty { return name }
        let owners = metadata["ownerReferences"] as? [[String: Any]] ?? []
        guard let owner = owners.first else { return "" }
        let ownerKind = string(owner["kind"])
        var ownerName = string(owner["name"])
        if ownerKind == "ReplicaSet", let dashRange = ownerName.range(of: "-", options: .backwards) {
            let suffix = ownerName[dashRange.upperBound...]
            if suffix.count >= 8, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) {
                ownerName = String(ownerName[ownerName.startIndex..<dashRange.lowerBound])
            }
        }
        return ownerName.isEmpty ? ownerKind : ownerName
    }

    private static func ownerChain(_ metadata: [String: Any]) -> String {
        let owners = metadata["ownerReferences"] as? [[String: Any]] ?? []
        guard let owner = owners.first else { return "-" }
        let kind = string(owner["kind"])
        let name = string(owner["name"])
        guard !kind.isEmpty, !name.isEmpty else { return "-" }
        if kind == "ReplicaSet", let deployment = deploymentName(fromReplicaSet: name), deployment != name {
            return "ReplicaSet/\(name) -> Deployment/\(deployment)"
        }
        return "\(kind)/\(name)"
    }

    private static func deploymentName(fromReplicaSet name: String) -> String? {
        guard let dashRange = name.range(of: "-", options: .backwards) else { return nil }
        let suffix = name[dashRange.upperBound...]
        guard suffix.count >= 8, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return String(name[name.startIndex..<dashRange.lowerBound])
    }

    private static func serviceRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let spec = dict(item["spec"])
        let ports = (spec["ports"] as? [[String: Any]] ?? []).map { "\(int($0["port"], defaultValue: 0))/\(string($0["protocol"]))" }.joined(separator: ", ")
        let ingress = (dict(dict(item["status"])["loadBalancer"])["ingress"] as? [[String: Any]] ?? []).map { string($0["ip"]).isEmpty ? string($0["hostname"]) : string($0["ip"]) }.joined(separator: ", ")
        // `spec.selector` is the standard field a Service uses to find its Pods —
        // generic across every Service, never assumed from an app-specific label.
        let selector = encodedLabels(dict(spec["selector"]))
        return row(key(metadata), ["Namespace": namespace(metadata), "Name": string(metadata["name"]), "Type": string(spec["type"]), "Cluster IP": string(spec["clusterIP"]), "External": ingress.isEmpty ? "-" : ingress, "Ports": ports, "Age": age(metadata), "Selector": selector])
    }

    private static func ingressRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let spec = dict(item["spec"])
        let rules = spec["rules"] as? [[String: Any]] ?? []
        let hosts = rules.map { string($0["host"]) }.filter { !$0.isEmpty }.joined(separator: ", ")
        let services = rules.flatMap { rule -> [String] in
            let paths = dict(rule["http"])["paths"] as? [[String: Any]] ?? []
            return paths.compactMap { path in
                let backend = dict(path["backend"])
                let service = dict(backend["service"])
                let name = string(service["name"])
                return name.isEmpty ? nil : name
            }
        }.sorted().joined(separator: ", ")
        let tls = ((spec["tls"] as? [[String: Any]])?.isEmpty == false) ? "Yes" : "No"
        let ingress = (dict(dict(item["status"])["loadBalancer"])["ingress"] as? [[String: Any]] ?? []).map { string($0["ip"]).isEmpty ? string($0["hostname"]) : string($0["ip"]) }.joined(separator: ", ")
        return row(key(metadata), ["Namespace": namespace(metadata), "Name": string(metadata["name"]), "Class": string(spec["ingressClassName"]), "Hosts": hosts, "TLS": tls, "Address": ingress, "Age": age(metadata), "Services": services])
    }

    private static func configMapRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let dataKeys = dict(item["data"]).keys.sorted().joined(separator: ", ")
        return row(key(metadata), [
            "Namespace": namespace(metadata),
            "Name": string(metadata["name"]),
            "Keys": String(dict(item["data"]).count),
            "Data Keys": dataKeys.isEmpty ? "-" : dataKeys,
            "Age": age(metadata)
        ])
    }

    private static func eventRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let involved = dict(item["involvedObject"])
        let type = string(item["type"])
        let lastSeen = string(item["lastTimestamp"]).isEmpty ? string(item["eventTime"]) : string(item["lastTimestamp"])
        return row(
            key(metadata),
            ["Namespace": namespace(metadata), "Object": "\(string(involved["kind"]))/\(string(involved["name"]))", "Type": type, "Reason": string(item["reason"]), "Message": string(item["message"]), "Last": relativeAge(from: lastSeen), "Count": String(int(item["count"], defaultValue: 1))],
            warning: type.lowercased() != "normal",
            sortValue: lastSeen
        )
    }

    private static func parseSecretTable(_ stdout: String) -> KubernetesResourceList {
        let rows = stdout.split(separator: "\n").map { line -> KubernetesResourceRow in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let hasNamespace = parts.count >= 5
            let namespace = hasNamespace ? parts[0] : "-"
            let offset = hasNamespace ? 1 : 0
            let name = parts.indices.contains(offset) ? parts[offset] : ""
            let type = parts.indices.contains(offset + 1) ? parts[offset + 1] : ""
            let data = parts.indices.contains(offset + 2) ? parts[offset + 2] : ""
            let age = parts.indices.contains(offset + 3) ? parts[offset + 3] : ""
            return row("\(namespace)/\(name)", ["Namespace": namespace, "Name": name, "Type": type, "Keys": data, "Age": age])
        }
        return list(.secretMetadata, ["Namespace", "Name", "Type", "Keys", "Age"], rows)
    }

    private static func row(_ id: String, _ cells: [String: String], warning: Bool = false, sortValue: String? = nil) -> KubernetesResourceRow {
        KubernetesResourceRow(id: id, cells: cells, warning: warning, sortValue: sortValue)
    }

    private static func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func string(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
    private static func int(_ value: Any?, defaultValue: Int) -> Int { value as? Int ?? Int(string(value)) ?? defaultValue }
    private static func namespace(_ metadata: [String: Any]) -> String { string(metadata["namespace"]).isEmpty ? "default" : string(metadata["namespace"]) }
    /// `"key=value,key2=value2"`, sorted for stable output — the one shared encoding
    /// used for a Pod's own labels, a Service's `spec.selector`, and a workload's
    /// `spec.selector.matchLabels`, so `KubernetesRelatedPods` has exactly one format
    /// to parse regardless of which resource kind it came from.
    private static func encodedLabels(_ labels: [String: Any]) -> String {
        labels.compactMap { key, value -> String? in
            guard let value = value as? String else { return nil }
            return "\(key)=\(value)"
        }.sorted().joined(separator: ",")
    }
    private static func key(_ metadata: [String: Any]) -> String { "\(namespace(metadata))/\(string(metadata["name"]))" }
    private static func age(_ metadata: [String: Any]) -> String {
        relativeAge(from: string(metadata["creationTimestamp"]))
    }

    private static func relativeAge(from timestamp: String) -> String {
        guard !timestamp.isEmpty else { return "-" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        guard let date else { return timestamp }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        let days = hours / 24
        if days < 60 { return "\(days)d" }
        let months = days / 30
        if months < 24 { return "\(months)mo" }
        return "\(days / 365)y"
    }
}
