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
        case .cronJobs: return list(kind, ["Namespace", "Name", "Schedule", "Suspend", "Active", "Last Schedule", "Age"], items.map(cronJobRow))
        case .services: return list(kind, ["Namespace", "Name", "Type", "Cluster IP", "External", "Ports", "Age"], items.map(serviceRow))
        case .ingress: return list(kind, ["Namespace", "Name", "Class", "Hosts", "TLS", "Address", "Age"], items.map(ingressRow))
        case .configMaps: return list(kind, ["Namespace", "Name", "Keys", "Age"], items.map(configMapRow))
        case .events: return list(kind, ["Namespace", "Object", "Type", "Reason", "Message", "Last", "Count"], items.map(eventRow).sorted { ($0.sortValue ?? "") > ($1.sortValue ?? "") })
        case .hpa: return list(kind, ["Namespace", "Name", "Reference", "Targets", "MinPods", "MaxPods", "Replicas", "Age"], items.map(hpaRow))
        case .pvc: return list(kind, ["Namespace", "Name", "Status", "Volume", "Capacity", "Access Modes", "StorageClass", "Age"], items.map(pvcRow))
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

        let capacity = dict(status["capacity"])
        let cpuCap = string(capacity["cpu"])
        let memCap = string(capacity["memory"])
        let diskCap = string(capacity["ephemeral-storage"])

        // A node that reports no capacity says so. The previous defaults — "4 vCPU",
        // "16 GiB", "80 GiB" — were indistinguishable from a real reading.
        let unknown = KubernetesGitOpsService.unknownValue
        let cpuText = cpuCap.isEmpty ? unknown : "\(cpuCap) vCPU"
        let memText = memCap.isEmpty ? unknown : (memCap.hasSuffix("Ki") ? String(format: "%.1f GiB", Double(int(memCap.dropLast(2), defaultValue: 0)) / 1_048_576.0) : memCap)
        let diskText = diskCap.isEmpty ? unknown : (diskCap.hasSuffix("Ki") ? String(format: "%.0f GiB", Double(int(diskCap.dropLast(2), defaultValue: 0)) / 1_048_576.0) : diskCap)
        let allocatable = dict(status["allocatable"])

        return row(string(metadata["name"]), [
            "Name": string(metadata["name"]),
            "Ready": ready ? "Ready" : "Not ready",
            "Roles": roles.isEmpty ? "-" : roles,
            "CPU": cpuText,
            "Memory": memText,
            "Disk": diskText,
            "Version": string(dict(status["nodeInfo"])["kubeletVersion"]),
            "Age": age(metadata),
            "IP": ip,
            // Not shown as columns — the telemetry panel reads these to work out how
            // much of the cluster is committed and how much is actually in use.
            "Pod Capacity": string(allocatable["pods"]),
            "Allocatable CPU": string(allocatable["cpu"]),
            "Allocatable Memory": string(allocatable["memory"])
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
        // Pull image from spec.template.spec.containers (Deployment/StatefulSet) or
        // spec.jobTemplate.spec.template.spec.containers (CronJob) — first container wins.
        let templateSpec = dict(dict(dict(spec["template"])["spec"]))
        let specContainers = templateSpec["containers"] as? [[String: Any]] ?? []
        let image = imageTag(specContainers)
        return row(key(metadata), [
            "Namespace": namespace(metadata),
            "Kind": string(item["kind"]),
            "Name": string(metadata["name"]),
            "Ready": "\(ready)/\(desired)",
            "Available": String(int(status["availableReplicas"], defaultValue: int(status["currentNumberScheduled"], defaultValue: 0))),
            "Age": age(metadata),
            "Image": image,
            "Selector": selector
        ], warning: ready < desired)
    }

    private static func podRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let status = dict(item["status"])
        let spec = dict(item["spec"])
        let containers = status["containerStatuses"] as? [[String: Any]] ?? []
        let specContainers = spec["containers"] as? [[String: Any]] ?? []
        let ready = containers.filter { ($0["ready"] as? Bool) == true }.count
        let restarts = containers.reduce(0) { $0 + int($1["restartCount"], defaultValue: 0) }
        let phase = string(status["phase"])
        let crashLoop = containers.contains { container in
            let reason = string(dict(dict(container["state"])["waiting"])["reason"]).lowercased()
            return reason.contains("crashloop") || reason.contains("backoff")
        }

        // Summed over every container, not just the first: a pod's footprint on the
        // scheduler includes its sidecars. A pod that declares no request at all is
        // reported as unset — the previous defaults of "100m"/"256Mi" made an
        // unbounded pod look like a modest one.
        let cpuRequestCores = totalRequest(specContainers, key: "cpu", parse: KubernetesMetricsReader.cores)
        let memRequestBytes = totalRequest(specContainers, key: "memory", parse: KubernetesMetricsReader.bytes)
        let cpuReq = cpuRequestCores.map { formatCores($0) } ?? KubernetesGitOpsService.unknownValue
        let memReq = memRequestBytes.map { formatBytes($0) } ?? KubernetesGitOpsService.unknownValue
        // Prefer the running imageID digest (what's actually live) if available,
        // otherwise fall back to spec.containers[].image (what was requested).
        let runningImage = containers.compactMap { $0["image"] as? String }.first ?? ""
        let image = runningImage.isEmpty ? imageTag(specContainers) : shortImageTag(runningImage, count: specContainers.count)

        return row(key(metadata), [
            "Namespace": namespace(metadata),
            "Name": string(metadata["name"]),
            "Status": crashLoop ? "CrashLoopBackOff" : phase,
            "Ready": "\(ready)/\(containers.count)",
            "Restarts": String(restarts),
            "CPU": cpuReq,
            "Memory": memReq,
            "Age": age(metadata),
            "Image": image,
            "Node": string(spec["nodeName"]),
            "Pod IP": string(status["podIP"]),
            "QoS": string(status["qosClass"]),
            "Owner": ownerChain(metadata),
            "Workload": workloadLabel(metadata),
            // Not shown as a column — the map reads it to draw Pod→PVC edges only
            // for volumes this pod actually mounts.
            "PVCs": claimNames(spec),
            "Labels": encodedLabels(dict(metadata["labels"])),
            // Not shown as columns — read by the telemetry panel.
            "Memory Limit": memoryLimit(spec),
            "CPU Request Cores": cpuRequestCores.map { String($0) } ?? "",
            "Memory Request Bytes": memRequestBytes.map { String($0) } ?? ""
        ], warning: phase != "Running" || crashLoop)
    }

    /// Best-effort "what this pod belongs to" for display only (e.g. a Logs pod
    /// picker) — prefers common app labels, falls back to the owning
    /// controller's kind/name (stripping the ReplicaSet hash suffix so it reads
    /// as the Deployment name), empty if neither is present.
    /// A pod's total request for one resource, or `nil` when no container declares it.
    private static func totalRequest(
        _ containers: [[String: Any]],
        key: String,
        parse: (String) -> Double?
    ) -> Double? {
        var total: Double = 0
        var declared = false
        for container in containers {
            let requests = dict(dict(container["resources"])["requests"])
            guard let raw = requests[key], let value = parse(String(describing: raw)) else { continue }
            total += value
            declared = true
        }
        return declared ? total : nil
    }

    private static func formatCores(_ cores: Double) -> String {
        cores >= 1 ? String(format: "%.2g", cores) : "\(Int((cores * 1000).rounded()))m"
    }

    private static func formatBytes(_ bytes: Double) -> String {
        let gib = bytes / 1_073_741_824
        if gib >= 1 { return String(format: "%.1fGi", gib) }
        return "\(Int((bytes / 1_048_576).rounded()))Mi"
    }

    /// The pod's total declared memory limit, summed across its containers. Empty
    /// when any container leaves the limit unset — a pod that can grow without bound
    /// has no threshold to be measured against.
    private static func memoryLimit(_ spec: [String: Any]) -> String {
        let containers = spec["containers"] as? [[String: Any]] ?? []
        guard !containers.isEmpty else { return "" }
        var total: Double = 0
        for container in containers {
            let limits = dict(dict(container["resources"])["limits"])
            guard let raw = limits["memory"],
                  let bytes = KubernetesMetricsReader.bytes(String(describing: raw)) else { return "" }
            total += bytes
        }
        return String(Int(total))
    }

    /// The PersistentVolumeClaims this pod mounts, from `spec.volumes[]`.
    /// Comma-joined; empty for stateless pods.
    private static func claimNames(_ spec: [String: Any]) -> String {
        let volumes = spec["volumes"] as? [[String: Any]] ?? []
        return volumes.compactMap { volume -> String? in
            let name = string(dict(volume["persistentVolumeClaim"])["claimName"])
            return name.isEmpty ? nil : name
        }.joined(separator: ",")
    }

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

    private static func cronJobRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let spec = dict(item["spec"])
        let status = dict(item["status"])
        let schedule = string(spec["schedule"])
        let suspend = (spec["suspend"] as? Bool) == true ? "True" : "False"
        let active = (status["active"] as? [[String: Any]] ?? []).count
        let lastScheduleTime = string(status["lastScheduleTime"])
        let formattedLastSchedule = relativeAge(from: lastScheduleTime)
        return row(key(metadata), [
            "Namespace": namespace(metadata),
            "Name": string(metadata["name"]),
            "Schedule": schedule,
            "Suspend": suspend,
            "Active": String(active),
            "Last Schedule": formattedLastSchedule,
            "Age": age(metadata)
        ], warning: suspend == "True" || active > 3)
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

    public static func genericCRDRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let status = dict(item["status"])
        let name = string(metadata["name"])
        let ns = namespace(metadata)
        let kind = string(item["kind"])
        let phase = string(status["phase"]).isEmpty ? (string(status["state"]).isEmpty ? "Active" : string(status["state"])) : string(status["phase"])
        return row("\(ns)/\(name)", [
            "Namespace": ns,
            "Kind": kind.isEmpty ? "CustomResource" : kind,
            "Name": name,
            "Status": phase,
            "Age": age(metadata)
        ])
    }

    private static func hpaRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let spec = dict(item["spec"])
        let status = dict(item["status"])
        let targetRef = dict(spec["scaleTargetRef"])
        let refName = string(targetRef["name"])
        let refKind = string(targetRef["kind"])
        let ref = refName.isEmpty ? "-" : "\(refKind)/\(refName)"
        let currentReplicas = string(status["currentReplicas"])
        let minPods = string(spec["minReplicas"])
        let maxPods = string(spec["maxReplicas"])
        let ns = namespace(metadata)
        return row("\(ns)/\(string(metadata["name"]))", [
            "Namespace": ns,
            "Name": string(metadata["name"]),
            "Reference": ref,
            "Targets": "active",
            "MinPods": minPods.isEmpty ? "1" : minPods,
            "MaxPods": maxPods.isEmpty ? "-" : maxPods,
            "Replicas": currentReplicas.isEmpty ? "0" : currentReplicas,
            "Age": age(metadata)
        ])
    }

    private static func pvcRow(_ item: [String: Any]) -> KubernetesResourceRow {
        let metadata = dict(item["metadata"])
        let spec = dict(item["spec"])
        let status = dict(item["status"])
        let capacity = dict(status["capacity"])
        let storage = string(capacity["storage"])
        let ns = namespace(metadata)
        return row("\(ns)/\(string(metadata["name"]))", [
            "Namespace": ns,
            "Name": string(metadata["name"]),
            "Status": string(status["phase"]).isEmpty ? "Bound" : string(status["phase"]),
            "Volume": string(spec["volumeName"]).isEmpty ? "-" : string(spec["volumeName"]),
            "Capacity": storage.isEmpty ? "-" : storage,
            "Access Modes": (spec["accessModes"] as? [String])?.joined(separator: ",") ?? "-",
            "StorageClass": string(spec["storageClassName"]).isEmpty ? "-" : string(spec["storageClassName"]),
            "Age": age(metadata)
        ])
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
        let years = days / 365
        let remDays = days % 365
        return remDays > 0 ? "\(years)y \(remDays)d" : "\(years)y"
    }

    /// Extracts a compact, human-readable image reference from `spec.containers`.
    /// Strips SHA digests from the tag portion (e.g. `@sha256:abc...`) — those are
    /// visible in the Pod inspector. Shows only the first container; appends
    /// `+N more` when there are additional containers so the table stays compact.
    private static func imageTag(_ containers: [[String: Any]]) -> String {
        guard let first = containers.first,
              let raw = first["image"] as? String, !raw.isEmpty else { return "-" }
        let cleaned = shortImageTag(raw, count: containers.count)
        return cleaned
    }

    /// Normalises a raw image ref to a tidy `name:tag` or `registry/name:tag` string.
    /// - Strips `@sha256:…` digest suffixes (the digest is shown in the inspector).
    /// - Strips the `:latest` tag to reduce noise (it's implied).
    /// - Appends `+N` when the pod has additional containers.
    private static func shortImageTag(_ raw: String, count: Int) -> String {
        // Drop digest, keep only the `registry/name:tag` portion.
        var ref = raw.components(separatedBy: "@").first ?? raw
        // Drop `:latest` tag — it adds no information.
        if ref.hasSuffix(":latest") { ref = String(ref.dropLast(":latest".count)) }
        let suffix = count > 1 ? " +\(count - 1)" : ""
        return ref.isEmpty ? "-" : ref + suffix
    }
}
