import Foundation

/// One environment variable exactly as the pod spec declares it.
///
/// A literal `value:` in a pod spec is not a Secret resource — it is plaintext
/// visible to anyone who can read the pod — so it is shown. A value sourced from a
/// Secret is *never* fetched: only the reference (`Secret db-creds/password`) is
/// recorded, so CTX never holds, displays, logs or caches the secret itself.
public struct EnvVarItem: Identifiable, Equatable, Sendable {
    /// `source` participates because `envFrom` entries all share the placeholder
    /// name "(all keys)" — a container pulling in two Secrets would otherwise emit
    /// two rows with identical ids, which breaks `ForEach` identity in SwiftUI.
    public var id: String { "\(container)/\(name)/\(source)" }
    public let container: String
    public let name: String
    /// Literal value from the spec. Empty when the value comes from a reference.
    public let value: String
    /// Where a referenced value comes from, e.g. "Secret db-creds/password" or
    /// "field spec.nodeName". Empty for literal values.
    public let source: String
    /// True when the value lives in a Secret. The value is not read.
    public let isSecret: Bool

    public init(name: String, value: String = "", container: String = "", source: String = "", isSecret: Bool = false) {
        self.container = container
        self.name = name
        self.value = value
        self.source = source
        self.isSecret = isSecret
    }
}

public struct ProbeInfo: Identifiable, Equatable, Sendable {
    public var id: String { "\(container)/\(type)" }
    public let container: String
    /// Readiness, Liveness, or Startup.
    public let type: String
    /// Human-readable target: "GET /healthz:8080", "TCP :5432", or the exec command.
    public let target: String
    public let delaySeconds: Int
    public let periodSeconds: Int
    public let isConfigured: Bool

    public init(
        type: String,
        target: String = "",
        container: String = "",
        delaySeconds: Int = 0,
        periodSeconds: Int = 0,
        isConfigured: Bool = true
    ) {
        self.container = container
        self.type = type
        self.target = target
        self.delaySeconds = delaySeconds
        self.periodSeconds = periodSeconds
        self.isConfigured = isConfigured
    }
}

/// Effective security posture for one container: the container's own
/// `securityContext` where it sets a field, falling back to the pod-level one —
/// which is exactly how the kubelet resolves it.
public struct SecurityContextAudit: Equatable, Sendable {
    public let container: String
    /// `runAsUser` as declared, or unknown when neither level sets it.
    public let runAsUser: String
    public let isRoot: Bool
    public let isReadOnlyRootFS: Bool
    public let isPrivileged: Bool
    public let allowPrivilegeEscalation: Bool
    /// Linux capabilities added beyond the default set.
    public let addedCapabilities: [String]

    public init(
        container: String = "",
        runAsUser: String = KubernetesGitOpsService.unknownValue,
        isRoot: Bool = false,
        isReadOnlyRootFS: Bool = false,
        isPrivileged: Bool = false,
        allowPrivilegeEscalation: Bool = false,
        addedCapabilities: [String] = []
    ) {
        self.container = container
        self.runAsUser = runAsUser
        self.isRoot = isRoot
        self.isReadOnlyRootFS = isReadOnlyRootFS
        self.isPrivileged = isPrivileged
        self.allowPrivilegeEscalation = allowPrivilegeEscalation
        self.addedCapabilities = addedCapabilities
    }
}

/// Declared requests and limits. Absent entries stay absent — an unset limit is a
/// meaningful finding (the container can consume the whole node), not a value to
/// fill in with a plausible-looking default.
public struct ResourceAllocation: Equatable, Sendable {
    public let container: String
    public let cpuRequest: String?
    public let cpuLimit: String?
    public let memoryRequest: String?
    public let memoryLimit: String?

    public init(
        container: String = "",
        cpuRequest: String? = nil,
        cpuLimit: String? = nil,
        memoryRequest: String? = nil,
        memoryLimit: String? = nil
    ) {
        self.container = container
        self.cpuRequest = cpuRequest
        self.cpuLimit = cpuLimit
        self.memoryRequest = memoryRequest
        self.memoryLimit = memoryLimit
    }
}

public struct ContainerSpecInsight: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let image: String
    public let isInitContainer: Bool
    public let env: [EnvVarItem]
    public let probes: [ProbeInfo]
    public let security: SecurityContextAudit
    public let resources: ResourceAllocation

    public init(
        name: String,
        image: String,
        isInitContainer: Bool = false,
        env: [EnvVarItem] = [],
        probes: [ProbeInfo] = [],
        security: SecurityContextAudit = SecurityContextAudit(),
        resources: ResourceAllocation = ResourceAllocation()
    ) {
        self.name = name
        self.image = image
        self.isInitContainer = isInitContainer
        self.env = env
        self.probes = probes
        self.security = security
        self.resources = resources
    }
}

public struct PodSpecInsight: Equatable, Sendable {
    public let containers: [ContainerSpecInsight]
    public let serviceAccount: String
    public let nodeName: String
    public let status: KubernetesCheckStatus
    public let diagnostic: KubernetesCommandDiagnostic?

    public init(
        containers: [ContainerSpecInsight] = [],
        serviceAccount: String = KubernetesGitOpsService.unknownValue,
        nodeName: String = KubernetesGitOpsService.unknownValue,
        status: KubernetesCheckStatus = .notChecked,
        diagnostic: KubernetesCommandDiagnostic? = nil
    ) {
        self.containers = containers
        self.serviceAccount = serviceAccount
        self.nodeName = nodeName
        self.status = status
        self.diagnostic = diagnostic
    }

    public var allEnv: [EnvVarItem] { containers.flatMap(\.env) }
    public var allProbes: [ProbeInfo] { containers.flatMap(\.probes) }
}

/// A real backing address behind a Service, as reported by its Endpoints object.
public struct EndpointTarget: Identifiable, Equatable, Sendable {
    public var id: String { "\(namespace)/\(name):\(targetPort)" }
    public let name: String
    public let namespace: String
    public let address: String
    public let targetPort: String
    /// Kubernetes splits Endpoints into ready and not-ready addresses; not-ready
    /// backends are exactly what someone debugging a Service needs to see.
    public let isHealthy: Bool

    public init(name: String, namespace: String, address: String = "", targetPort: String = "", isHealthy: Bool = true) {
        self.name = name
        self.namespace = namespace
        self.address = address
        self.targetPort = targetPort
        self.isHealthy = isHealthy
    }
}

public struct ServiceEndpointsInsight: Equatable, Sendable {
    public let targets: [EndpointTarget]
    public let status: KubernetesCheckStatus
    public let diagnostic: KubernetesCommandDiagnostic?

    public init(
        targets: [EndpointTarget] = [],
        status: KubernetesCheckStatus = .notChecked,
        diagnostic: KubernetesCommandDiagnostic? = nil
    ) {
        self.targets = targets
        self.status = status
        self.diagnostic = diagnostic
    }
}
