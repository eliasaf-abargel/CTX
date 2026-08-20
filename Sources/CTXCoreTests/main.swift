import Combine
import CTXCore
import Foundation

func testProviderLabelsStayCloudSpecific() {
    assert(CloudProfile(provider: .aws, name: "prod").accountLabel == "AWS Account")
    assert(CloudProfile(provider: .gcp, name: "prod").roleLabel == "GCP Account")
    assert(CloudProfile(provider: .azure, name: "prod").regionLabel == "Default Location")
    assert(CloudProfile(provider: .kubernetes, name: "prod").typeDescription == "Kubernetes Context")
}

func testEnvironmentInferencePrefersSpecificProfileSignals() {
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "prod-admin")) == .production)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "stage-sso")) == .staging)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "dev-sandbox")) == .development)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "redshift-prod")) == .data)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "ops-admin")) == .admin)
}

func testBuiltInFolderIdentityIsStable() {
    let folder = CloudFolder.builtIn(provider: .aws, environment: .production)

    assert(folder.id == "AWS:Production")
    assert(folder.provider == .aws)
    assert(folder.name == "Production")
    assert(folder.icon == .server)
    assert(folder.isCustom == false)
}

func testAWSDraftDuplicatePreservesConfigurationAndRenamesCopy() {
    let profile = CloudProfile(
        provider: .aws,
        name: "prod-admin",
        accountID: "123456789012",
        roleName: "AdministratorAccess",
        region: "us-east-1",
        ssoStartURL: "https://example.awsapps.com/start",
        ssoRegion: "us-east-1"
    )

    let draft = AWSProfileDraft(profile: profile, duplicate: true)

    assert(draft.name == "prod-admin-copy")
    assert(draft.accountID == "123456789012")
    assert(draft.roleName == "AdministratorAccess")
    assert(draft.defaultRegion == "us-east-1")
    assert(draft.ssoStartURL == "https://example.awsapps.com/start")
    assert(draft.ssoRegion == "us-east-1")
}

func testKubernetesContextProfileMapsToCloudProfile() {
    let detection = EnvironmentDetectionResult(type: .production, confidence: 0.9, source: "context")
    let profile = KubernetesContextProfile(
        contextName: "eks-prod",
        clusterName: "prod-cluster",
        userName: "prod-user",
        namespace: "default",
        kubeconfigPath: "/tmp/kubeconfig",
        providerType: .eks,
        environmentDetection: detection,
        isCurrent: true,
        clusterMetadata: ClusterMetadata(id: "prod-cluster", name: "prod-cluster", serverURL: "https://example.eks.amazonaws.com")
    )

    assert(profile.id == "/tmp/kubeconfig:eks-prod")
    assert(profile.environmentType == .production)
    assert(profile.providerType == .eks)
    let cloudProfile = KubernetesProfileAdapter.cloudProfile(from: profile)
    assert(cloudProfile.provider == .kubernetes)
    assert(cloudProfile.name == "eks-prod")
    assert(cloudProfile.accountID == "prod-cluster")
    assert(cloudProfile.roleName == "prod-user")
    assert(cloudProfile.region == "default")
}

func testEnvironmentDetection() {
    assert(EnvironmentDetector.detect(contextName: "shop-prod", clusterName: "").type == .production)
    assert(EnvironmentDetector.detect(contextName: "shop-staging", clusterName: "").type == .staging)
    assert(EnvironmentDetector.detect(contextName: "dev-west", clusterName: "").type == .development)
    assert(EnvironmentDetector.detect(contextName: "ops", clusterName: "root-management").type == .admin)
    assert(EnvironmentDetector.detect(contextName: "shared", clusterName: "shared").type == .unknown)
}

func testKubernetesProviderDetection() {
    assert(KubernetesProviderDetector.detect(contextName: "prod", clusterName: "eks-prod", serverURL: "") == .eks)
    assert(KubernetesProviderDetector.detect(contextName: "gke_project_zone_cluster", clusterName: "cluster", serverURL: "") == .gke)
    assert(KubernetesProviderDetector.detect(contextName: "aks-prod", clusterName: "prod", serverURL: "") == .aks)
    assert(KubernetesProviderDetector.detect(contextName: "kind-local", clusterName: "kind-local", serverURL: "https://127.0.0.1:6443") == .local)
    assert(KubernetesProviderDetector.detect(contextName: "shared", clusterName: "shared", serverURL: "https://10.0.0.1") == .unknown)
}

func testKubeConfigDiscoverySingleFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let path = dir.appendingPathComponent("config")
    try kubeconfig(context: "eks-prod", cluster: "prod-cluster", user: "prod-user", namespace: "platform", server: "https://prod.eks.amazonaws.com")
        .write(to: path, atomically: true, encoding: .utf8)

    let service = KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
    let result = service.discover(paths: [path])

    assert(result.errors.isEmpty)
    assert(result.currentContext == "eks-prod")
    assert(result.contexts.count == 1)
    assert(result.contexts[0].contextName == "eks-prod")
    assert(result.contexts[0].clusterName == "prod-cluster")
    assert(result.contexts[0].userName == "prod-user")
    assert(result.contexts[0].namespace == "platform")
    assert(result.contexts[0].kubeconfigPath == path.path)
    assert(result.contexts[0].providerType == .eks)
    assert(result.contexts[0].environmentType == .production)
    assert(result.contexts[0].isCurrent)
}

func testKubeConfigDiscoveryHandlesNameAfterNestedClusterOrContextKey() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-name-after-nested-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // `aws eks update-kubeconfig` and merged kubeconfigs (Rancher Desktop, etc.)
    // write list items as "- cluster:" / "- context:" first, with `name:` as a
    // later sibling key — not "- name:" as the item's opening line. A parser
    // that only treats "- name:" as a new-item boundary silently drops every
    // item after the first and corrupts the one it does keep by mixing the
    // first item's name with the last item's fields.
    let path = dir.appendingPathComponent("config")
    let raw = """
    apiVersion: v1
    clusters:
    - cluster:
        server: https://alpha.example.com
      name: alpha-cluster
    - cluster:
        server: https://beta.example.com
      name: beta-cluster
    contexts:
    - context:
        cluster: alpha-cluster
        user: alpha-user
      name: alpha
    - context:
        cluster: beta-cluster
        user: beta-user
        namespace: apps
      name: beta
    current-context: beta
    """
    try raw.write(to: path, atomically: true, encoding: .utf8)

    let service = KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
    let result = service.discover(paths: [path])

    assert(result.errors.isEmpty)
    assert(result.currentContext == "beta")
    assert(result.contexts.count == 2, "both contexts must be discovered, not just the first or a merged one")

    let alpha = result.contexts.first { $0.contextName == "alpha" }
    assert(alpha?.clusterName == "alpha-cluster")
    assert(alpha?.userName == "alpha-user")
    assert(alpha?.clusterMetadata.serverURL == "https://alpha.example.com", "alpha's own cluster server must not leak from beta's")
    assert(alpha?.isCurrent == false)

    let beta = result.contexts.first { $0.contextName == "beta" }
    assert(beta?.clusterName == "beta-cluster")
    assert(beta?.userName == "beta-user")
    assert(beta?.namespace == "apps")
    assert(beta?.clusterMetadata.serverURL == "https://beta.example.com")
    assert(beta?.isCurrent == true)
}

func testKubeConfigDiscoveryUsesKubeconfigMultipath() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-multipath-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = dir.appendingPathComponent("first")
    let second = dir.appendingPathComponent("second")
    try kubeconfig(context: "kind-local", cluster: "kind-local", user: "kind-user", server: "https://127.0.0.1:6443")
        .write(to: first, atomically: true, encoding: .utf8)
    try kubeconfig(context: "aks-stage", cluster: "aks-stage", user: "aks-user", server: "https://example.azmk8s.io")
        .write(to: second, atomically: true, encoding: .utf8)

    let env = ["KUBECONFIG": "\(first.path):\(second.path)"]
    let service = KubeConfigDiscoveryService(environment: { env }, customPath: { nil })
    let result = service.discover()

    assert(result.errors.isEmpty)
    assert(Set(result.contexts.map(\.contextName)) == Set(["kind-local", "aks-stage"]))
    assert(result.contexts.first { $0.contextName == "kind-local" }?.providerType == .local)
    assert(result.contexts.first { $0.contextName == "aks-stage" }?.providerType == .aks)
    assert(result.contexts.first { $0.contextName == "aks-stage" }?.environmentType == .staging)
}

func testKubeConfigDiscoveryCustomPathOverridesKubeconfig() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-custom-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let custom = dir.appendingPathComponent("custom")
    let ignored = dir.appendingPathComponent("ignored")
    try kubeconfig(context: "custom-prod", cluster: "custom-cluster", user: "custom-user", server: "https://custom.eks.amazonaws.com")
        .write(to: custom, atomically: true, encoding: .utf8)
    try kubeconfig(context: "ignored-dev", cluster: "ignored-cluster", user: "ignored-user", server: "https://127.0.0.1:6443")
        .write(to: ignored, atomically: true, encoding: .utf8)

    let service = KubeConfigDiscoveryService(
        environment: { ["KUBECONFIG": ignored.path] },
        customPath: { custom.path }
    )
    let result = service.discover()

    assert(result.contexts.map(\.contextName) == ["custom-prod"])
    assert(result.contexts[0].kubeconfigPath == custom.path)
}

func testKubeConfigDiscoveryDeduplicatesContextNames() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-dedupe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = dir.appendingPathComponent("first")
    let second = dir.appendingPathComponent("second")
    try kubeconfig(context: "shared-prod", cluster: "first-cluster", user: "first-user", server: "https://first.eks.amazonaws.com")
        .write(to: first, atomically: true, encoding: .utf8)
    try kubeconfig(context: "shared-prod", cluster: "second-cluster", user: "second-user", server: "https://second.eks.amazonaws.com")
        .write(to: second, atomically: true, encoding: .utf8)

    let service = KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
    let result = service.discover(paths: [first, second])

    assert(result.contexts.count == 1)
    assert(result.contexts[0].clusterName == "first-cluster")
    assert(result.contexts[0].kubeconfigPath == first.path)
}

func testKubeConfigDiscoveryHandlesInvalidFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-invalid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let service = KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
    let result = service.discover(paths: [dir])

    assert(result.contexts.isEmpty)
    assert(result.errors.count == 1)
}

func testLocalProfileDiscoveryLoadsAWSAndKubernetesProfiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let awsConfig = dir.appendingPathComponent("aws-config")
    try """
    [default]
    region = us-east-1

    [profile ctx-test-dev]
    sso_account_id = 123456789012
    sso_role_name = Developer
    region = us-west-2
    """.write(to: awsConfig, atomically: true, encoding: .utf8)

    let kube = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(context: "ctx-test-kube", cluster: "ctx-test-cluster", user: "ctx-test-user", namespace: "apps", server: "https://127.0.0.1:6443")
        .write(to: kube, atomically: true, encoding: .utf8)

    let service = LocalProfileDiscoveryService(
        awsConfigURL: awsConfig,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
    )
    let result = service.discover(kubeconfigPaths: [kube])

    assert(result.profiles.contains { $0.provider == .aws && $0.name == "ctx-test-dev" })
    assert(!result.profiles.contains { $0.provider == .aws && $0.name == "default" })
    assert(result.kubernetesContexts.map(\.contextName) == ["ctx-test-kube"])
    assert(result.currentKubeContext == "ctx-test-kube")
    assert(result.profiles.contains { $0.provider == .kubernetes && $0.name == "ctx-test-kube" })
}

func testKubectlCommandConstruction() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kubectl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let kubectl = dir.appendingPathComponent("kubectl")
    try "#!/bin/sh\nexit 0\n".write(to: kubectl, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kubectl.path)

    let runner = KubectlRunner(environment: { ["PATH": dir.path] })
    let command = try runner.inspectionCommand(context: "dev-context", arguments: ["get", "pods", "--all-namespaces"])

    assert(command.executablePath == kubectl.path)
    assert(command.arguments == ["--context", "dev-context", "get", "pods", "--all-namespaces"])
}

func testKubectlRunnerAddsCliSearchPathToChildEnvironment() async throws {
    let runner = KubectlRunner(environment: { ["PATH": "/tmp/ctx-minimal-path"] })
    let command = KubectlCommand(
        executablePath: "/bin/sh",
        arguments: ["-c", "printf '%s' \"$PATH\""]
    )

    let result = try await runner.run(command, timeout: 1)

    assert(result.stdout.contains("/opt/homebrew/bin"))
    assert(result.stdout.contains("/usr/local/bin"))
}

func testPortForwardBuildsSafeServiceCommand() async {
    let kubectl = ScriptedKubectl()
    let service = KubernetesPortForwardService(kubectl: kubectl)
    let request = KubernetesPortForwardRequest(namespace: "app", targetKind: .service, targetName: "api", localPort: 18080, remotePort: 80)

    let session = await service.start(context: testKubernetesContext(), request: request)

    assert(session.status == .running)
    assert(session.localURL == "http://127.0.0.1:18080")
    assert(kubectl.startedCommands.count == 1)
    let command = kubectl.startedCommands[0]
    assert(Array(command.arguments.prefix(2)) == ["--context", "prod-context"])
    assert(command.arguments.contains("--kubeconfig"))
    assert(command.arguments.contains("/tmp/kubeconfig"))
    assert(command.arguments.contains("port-forward"))
    assert(command.arguments.contains("service/api"))
    assert(command.arguments.contains("--namespace"))
    assert(command.arguments.contains("app"))
    assert(command.arguments.contains("18080:80"))
    assert(command.arguments.contains("--address"))
    assert(command.arguments.contains("127.0.0.1"))
    assert(command.environmentOverrides["KUBECONFIG"] == "/tmp/kubeconfig")
}

func testPortForwardRejectsInvalidPortsBeforeStartingProcess() async {
    let kubectl = ScriptedKubectl()
    let service = KubernetesPortForwardService(kubectl: kubectl)
    let request = KubernetesPortForwardRequest(namespace: "app", targetKind: .service, targetName: "api", localPort: 0, remotePort: 80)

    let session = await service.start(context: testKubernetesContext(), request: request)

    assert(session.status == .failed)
    assert(kubectl.startedCommands.isEmpty)
}

func testPortForwardStopTerminatesProcess() async {
    let kubectl = ScriptedKubectl()
    let handle = FakeKubectlProcess()
    kubectl.processToStart = handle
    let service = KubernetesPortForwardService(kubectl: kubectl)
    let request = KubernetesPortForwardRequest(namespace: "app", targetKind: .service, targetName: "api", localPort: 18080, remotePort: 80)
    let session = await service.start(context: testKubernetesContext(), request: request)

    await service.stop(sessionID: session.id)

    assert(handle.terminated)
}

func testClusterOverviewMapsInspectionSummaries() async {
    let kubectl = ScriptedKubectl()
    kubectl.outputs["version --request-timeout=1s --output=json"] = .success("{}")
    KubernetesRBACResource.allCases.forEach { resource in
        var key = "auth can-i list \(resource.kubectlResource)"
        if resource.allNamespaces { key += " --all-namespaces" }
        kubectl.outputs[key] = .success("yes\n")
    }

    let summary = await ClusterHealthService(kubectl: kubectl, timeout: 1).overview(for: testKubernetesContext())

    assert(summary.apiStatus == .reachable)
    assert(summary.namespaces.status == .notChecked)
    assert(summary.nodes.status == .notChecked)
    assert(summary.pods.status == .notChecked)
    assert(summary.events.status == .notChecked)
    assert(summary.rbac.allSatisfy { $0.allowed == true })
    assert(!kubectl.commands.contains { $0.arguments.contains("namespaces") && $0.arguments.contains("get") })
    assert(!kubectl.commands.contains { $0.arguments.contains("nodes") && $0.arguments.contains("get") })
    assert(!kubectl.commands.contains { $0.arguments.contains("pods") && $0.arguments.contains("get") })
    assert(!kubectl.commands.contains { $0.arguments.contains("events") && $0.arguments.contains("get") })
}

func testClusterOverviewMapsRBACDeniedAndPermissionDenied() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("{}")
    kubectl.outputs["auth can-i list pods --all-namespaces"] = .success("no\n")

    let summary = await ClusterHealthService(kubectl: kubectl, timeout: 1).overview(for: testKubernetesContext())

    assert(summary.rbac.first { $0.resource == "Pods" }?.allowed == false)
    assert(summary.namespaces.status == .notChecked)
    assert(summary.namespaces.count == nil)
}

func testWorkloadsSummaryCountsWarningsAsUnhealthy() {
    let rows = [
        KubernetesResourceRow(id: "deployment/api", cells: ["Name": "api"], warning: false),
        KubernetesResourceRow(id: "deployment/worker", cells: ["Name": "worker"], warning: true)
    ]
    let summary = KubernetesWorkloadsSummary.summarize(rows: rows, status: .reachable)

    assert(summary.total == 2)
    assert(summary.healthy == 1)
    assert(summary.unhealthy == 1)
    assert(summary.status == .reachable)
}

func testPodsSummaryCountsStatusBuckets() {
    let rows = [
        KubernetesResourceRow(id: "pod/api", cells: ["Status": "Running"]),
        KubernetesResourceRow(id: "pod/scheduler", cells: ["Status": "Pending"]),
        KubernetesResourceRow(id: "pod/job", cells: ["Status": "Failed"]),
        KubernetesResourceRow(id: "pod/worker", cells: ["Status": "CrashLoopBackOff"])
    ]
    let summary = KubernetesPodsSummary.summarize(rows: rows, status: .reachable)

    assert(summary.total == 4)
    assert(summary.running == 1)
    assert(summary.pending == 1)
    assert(summary.failed == 1)
    assert(summary.crashLoopBackOff == 1)
    assert(summary.failing == 3)
}

func testServiceAndIngressSummariesCaptureEndpointVisibility() {
    let services = KubernetesServicesSummary.summarize(rows: [
        KubernetesResourceRow(id: "service/api", cells: ["External": "api.example.com"]),
        KubernetesResourceRow(id: "service/internal", cells: ["External": "-"])
    ], status: .reachable)
    let ingress = KubernetesIngressSummary.summarize(rows: [
        KubernetesResourceRow(id: "ingress/web", cells: ["Hosts": "web.example.com", "TLS": "Yes", "Address": "1.2.3.4"]),
        KubernetesResourceRow(id: "ingress/pending", cells: ["Hosts": "", "TLS": "No", "Address": ""])
    ], status: .reachable)

    assert(services.total == 2)
    assert(services.exposed == 1)
    assert(ingress.total == 2)
    assert(ingress.routed == 1)
    assert(ingress.tls == 1)
}

func testIngressRowsCaptureBackendServicesForTopology() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(items([
        [
            "metadata": ["namespace": "app", "name": "web", "creationTimestamp": "2026-01-01T00:00:00Z"],
            "spec": [
                "rules": [[
                    "host": "web.example.test",
                    "http": ["paths": [[
                        "backend": ["service": ["name": "web-service"]]
                    ]]]
                ]],
                "tls": [["hosts": ["web.example.test"]]]
            ],
            "status": ["loadBalancer": ["ingress": [["hostname": "lb.example.test"]]]]
        ]
    ]))
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    let result = await reader.list(kind: .ingress, context: testKubernetesContext(), namespace: .namespace("app"))

    assert(result.rows.first?.cells["Hosts"] == "web.example.test")
    assert(result.rows.first?.cells["Services"] == "web-service")
    assert(result.rows.first?.cells["TLS"] == "Yes")
}

func testEventsSummaryCapturesLatestWarningTimelineSignal() {
    let rows = [
        KubernetesResourceRow(id: "new-warning", cells: ["Type": "Warning", "Reason": "BackOff", "Object": "Pod/api", "Last": "2m"], warning: true),
        KubernetesResourceRow(id: "normal", cells: ["Type": "Normal", "Reason": "Pulled", "Object": "Pod/api", "Last": "3m"]),
        KubernetesResourceRow(id: "repeat-warning", cells: ["Type": "Warning", "Reason": "BackOff", "Object": "Pod/api", "Last": "5m"], warning: true),
        KubernetesResourceRow(id: "old-warning", cells: ["Type": "Warning", "Reason": "FailedScheduling", "Object": "Pod/worker", "Last": "9m"], warning: true)
    ]
    let summary = KubernetesEventsSummary.summarize(rows: rows, status: .reachable)

    assert(summary.warningCount == 3)
    assert(summary.latestWarningReason == "BackOff")
    assert(summary.latestWarningObject == "Pod/api")
    assert(summary.latestWarningLastSeen == "2m")
    assert(summary.topWarningReason == "BackOff")
    assert(summary.topWarningObject == "Pod/api")
    assert(summary.topWarningCount == 2)
}

func testEventObjectTargetParsesKnownResourceKinds() {
    let pod = KubernetesEventObjectTarget(object: "Pod/api", namespace: "app")
    let service = KubernetesEventObjectTarget(object: "Service/web", namespace: "app")
    let node = KubernetesEventObjectTarget(object: "Node/worker-node", namespace: "default")
    let ignored = KubernetesEventObjectTarget(object: "ReplicaSet/api-7f9c8d6b5", namespace: "app")

    assert(pod?.kind == .pods)
    assert(pod?.namespace == "app")
    assert(pod?.name == "api")
    assert(service?.kind == .services)
    assert(node?.kind == .nodes)
    assert(node?.namespace == nil)
    assert(ignored == nil)
}

func testClusterOverviewMapsTimeoutUnauthorizedAndMissingKubectl() async {
    let timedOutKubectl = ScriptedKubectl()
    timedOutKubectl.defaultOutput = .timeout
    let timeoutSummary = await ClusterHealthService(kubectl: timedOutKubectl, timeout: 1).overview(for: testKubernetesContext())
    assert(timeoutSummary.apiStatus == .timeout)

    let unauthorizedKubectl = ScriptedKubectl()
    unauthorizedKubectl.defaultOutput = .failure(stderr: "You must be logged in to the server")
    let unauthorizedSummary = await ClusterHealthService(kubectl: unauthorizedKubectl, timeout: 1).overview(for: testKubernetesContext())
    assert(unauthorizedSummary.apiStatus == .unauthorized)
    assert(unauthorizedSummary.rbac.allSatisfy { $0.allowed == nil && $0.status == .unauthorized })
    assert(!unauthorizedKubectl.commands.contains { $0.arguments.contains("auth") }, "RBAC must not run after API/auth fails")

    let missingKubectl = ScriptedKubectl()
    missingKubectl.error = KubectlRunnerError.kubectlNotFound
    let missingSummary = await ClusterHealthService(kubectl: missingKubectl, timeout: 1).overview(for: testKubernetesContext())
    assert(missingSummary.apiStatus == .kubectlMissing)
}

func testClusterOverviewPreservesContextAndKubeconfig() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(emptyItems())

    _ = await ClusterHealthService(kubectl: kubectl, timeout: 1).overview(for: testKubernetesContext())

    assert(kubectl.commands.allSatisfy { Array($0.arguments.prefix(2)) == ["--context", "prod-context"] })
    assert(kubectl.commands.allSatisfy { $0.arguments.contains("--kubeconfig") && $0.arguments.contains("/tmp/kubeconfig") })
    assert(kubectl.commands.allSatisfy { $0.environmentOverrides["KUBECONFIG"] == "/tmp/kubeconfig" })
}

func testClusterOverviewMapsContextMissingAndLocalProxyRefused() async {
    let missing = ScriptedKubectl()
    missing.defaultOutput = .failure(stderr: #"error: context "prod-context" does not exist"#)
    let missingSummary = await ClusterHealthService(kubectl: missing, timeout: 1).overview(for: testKubernetesContext())
    assert(missingSummary.apiStatus == .contextNotFound)
    assert(missingSummary.primaryFailure?.category == .contextNotFound)

    let proxy = ScriptedKubectl()
    proxy.defaultOutput = .failure(stderr: "The connection to the server 127.0.0.1:10003 was refused")
    let proxySummary = await ClusterHealthService(kubectl: proxy, timeout: 1).overview(for: testKubernetesContext())
    assert(proxySummary.apiStatus == .unreachable)
    assert(proxySummary.primaryFailure?.category == .localProxyUnavailable)
}

func testClusterOverviewMapsRBACDeniedStates() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(emptyItems())
    KubernetesRBACResource.allCases.forEach { resource in
        var key = "auth can-i list \(resource.kubectlResource)"
        if resource.allNamespaces { key += " --all-namespaces" }
        kubectl.outputs[key] = .success("no\n")
    }

    let summary = await ClusterHealthService(kubectl: kubectl, timeout: 1).overview(for: testKubernetesContext())

    assert(summary.rbac.allSatisfy { $0.allowed == false })
    assert(summary.rbac.allSatisfy { $0.status == .permissionDenied })
}

func testClusterOverviewDoesNotReadSecretValues() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("{}")

    _ = await ClusterHealthService(kubectl: kubectl, timeout: 1).overview(for: testKubernetesContext())

    assert(kubectl.commands.contains { $0.arguments.contains("auth") && $0.arguments.contains("secrets") })
    assert(!kubectl.commands.contains { command in
        let args = command.arguments
        return args.contains("get") && args.contains("secrets")
    })
}

func testKubernetesResourceReaderParsesNamespaces() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(items([
        ["metadata": ["name": "default", "creationTimestamp": "2026-01-01T00:00:00Z", "labels": ["kubernetes.io/metadata.name": "default"]], "status": ["phase": "Active"]],
        ["metadata": ["name": "production-namespace", "creationTimestamp": "2026-01-02T00:00:00Z"], "status": ["phase": "Active"]]
    ]))
    // The reader itself is always-live now — caching/staleness is the
    // ResourceRefreshCoordinator's job (see its own tests below), not the reader's.
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    let first = await reader.list(kind: .namespaces, context: testKubernetesContext(), namespace: .allNamespaces)
    let second = await reader.list(kind: .namespaces, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(first.status == .reachable)
    assert(first.rows.count == 2)
    assert(first.rows[0].cells["Name"] == "default")
    assert(first.rows[0].cells["Age"]?.contains("T") == false)
    assert(second.rows.count == 2)
    assert(kubectl.commands.count == 2, "reader has no cache of its own; every call reaches kubectl")
}

func testKubernetesResourceReaderAttachesResourceRefs() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(items([
        ["metadata": ["namespace": "app", "name": "api"], "spec": ["nodeName": "node-1"], "status": ["phase": "Running", "containerStatuses": [["ready": true, "restartCount": 0]]]]
    ]))
    let context = testKubernetesContext()
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    let pods = await reader.list(kind: .pods, context: context, namespace: .allNamespaces)
    let ref = pods.rows[0].ref

    assert(ref?.contextID == context.id)
    assert(ref?.contextName == context.contextName)
    assert(ref?.kubeconfigPath == context.kubeconfigPath)
    assert(ref?.kind == .pods)
    assert(ref?.namespace == "app")
    assert(ref?.name == "api")
}

func testNodesAreClusterScopedRegardlessOfNamespaceSelection() async {
    assert(KubernetesResourceKind.nodes.isClusterScoped)
    assert(KubernetesResourceKind.namespaces.isClusterScoped)
    assert(!KubernetesResourceKind.pods.isClusterScoped)

    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(emptyItems())
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    _ = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .namespace("team-a"))
    _ = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .allNamespaces)

    // Same cluster-scoped `get nodes` command regardless of which namespace was
    // selected when the call was made — Nodes never depends on namespace.
    assert(kubectl.commands[0].arguments == kubectl.commands[1].arguments)
    assert(!kubectl.commands[0].arguments.contains("--namespace"))
    assert(!kubectl.commands[0].arguments.contains("--all-namespaces"))
}

func testKubernetesResourceReaderUsesNamespaceScopes() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(emptyItems())
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    _ = await reader.list(kind: .pods, context: testKubernetesContext(), namespace: .namespace("production-namespace"))
    _ = await reader.list(kind: .services, context: testKubernetesContext(), namespace: .allNamespaces)
    _ = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .namespace("ignored"))
    _ = await reader.list(kind: .events, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(kubectl.commands[0].arguments.contains("--namespace"))
    assert(kubectl.commands[0].arguments.contains("production-namespace"))
    assert(kubectl.commands[0].arguments.contains("--request-timeout=20s"))
    assert(kubectl.commands[1].arguments.contains("--all-namespaces"))
    assert(kubectl.commands[1].arguments.contains("--request-timeout=20s"))
    assert(!kubectl.commands[2].arguments.contains("--namespace"))
    assert(!kubectl.commands[2].arguments.contains("--all-namespaces"))
    assert(kubectl.commands[2].arguments.contains("--request-timeout=20s"))
    assert(kubectl.commands[3].arguments.contains("--all-namespaces"))
    assert(kubectl.commands[3].arguments.contains("--request-timeout=30s"))
    assert(kubectl.commands.allSatisfy { $0.environmentOverrides["KUBECONFIG"] == "/tmp/kubeconfig" })
}

// MARK: - ResourceRefreshCoordinator

func testResourceRefreshCoordinatorCachesPerNamespaceScope() async {
    let reader = CountingResourceReader()
    let coordinator = ResourceRefreshCoordinator(reader: reader, staleThreshold: 60)
    let context = testKubernetesContext()

    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .namespace("demo-namespace"), kind: .pods, bypassCache: false)
    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .namespace("demo-namespace"), kind: .pods, bypassCache: false)
    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .namespace("staging-namespace"), kind: .pods, bypassCache: false)

    let calls = await reader.calls
    assert(calls.count == 2, "a fresh cache hit for the same namespace scope must not re-fetch; a different namespace must")
    assert(calls[0].namespace == "demo-namespace")
    assert(calls[1].namespace == "staging-namespace")
}

func testResourceRefreshCoordinatorIsolatesContexts() async {
    let reader = CountingResourceReader()
    let coordinator = ResourceRefreshCoordinator(reader: reader, staleThreshold: 60)
    let contextA = KubernetesContextProfile(
        contextName: "context-a",
        clusterName: "cluster-a",
        kubeconfigPath: "/tmp/kubeconfig-a",
        providerType: .eks,
        environmentDetection: EnvironmentDetectionResult(type: .development, confidence: 1, source: "test")
    )
    let contextB = KubernetesContextProfile(
        contextName: "context-b",
        clusterName: "cluster-b",
        kubeconfigPath: "/tmp/kubeconfig-b",
        providerType: .gke,
        environmentDetection: EnvironmentDetectionResult(type: .development, confidence: 1, source: "test")
    )
    assert(contextA.id != contextB.id)

    // Same kind, same namespace, two different contexts — must not share a cache entry.
    _ = await coordinator.fetch(contextID: contextA.id, context: contextA, namespace: .namespace("shared-namespace"), kind: .pods, bypassCache: false)
    _ = await coordinator.fetch(contextID: contextB.id, context: contextB, namespace: .namespace("shared-namespace"), kind: .pods, bypassCache: false)
    _ = await coordinator.fetch(contextID: contextA.id, context: contextA, namespace: .namespace("shared-namespace"), kind: .pods, bypassCache: false)

    let callCount = await reader.callCount
    assert(callCount == 2, "expected one live call per context, not \(callCount)")
}

func testResourceRefreshCoordinatorDeduplicatesConcurrentFetches() async {
    let reader = CountingResourceReader()
    await reader.setDelayNanoseconds(20_000_000)
    let coordinator = ResourceRefreshCoordinator(reader: reader)
    let context = testKubernetesContext()

    async let first = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .pods, bypassCache: false)
    async let second = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .pods, bypassCache: false)
    _ = await (first, second)

    let callCount = await reader.callCount
    assert(callCount == 1, "two concurrent identical requests must join one live call, not start two")
}

func testResourceRefreshCoordinatorPreservesGoodDataOnFailedRefresh() async {
    let reader = CountingResourceReader()
    let coordinator = ResourceRefreshCoordinator(reader: reader)
    let context = testKubernetesContext()

    let good = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: false)
    assert(good.list.status == .reachable)

    await reader.setResultProvider { kind, _ in
        KubernetesResourceList(kind: kind, columns: [], rows: [], status: .timeout, diagnostic: nil)
    }
    let failedRefresh = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: true)
    assert(failedRefresh.list.status == .timeout, "the caller should see the failure to be able to surface it")

    let stillCached = await coordinator.cachedList(contextID: context.id, namespace: .allNamespaces, kind: .nodes)
    assert(stillCached?.status == .reachable, "a failed refresh must not overwrite the last known-good cache entry")
}

func testResourceRefreshCoordinatorCancelDropsInFlightRequest() async {
    let reader = CountingResourceReader()
    await reader.setHoldUntilReleased(true)
    let coordinator = ResourceRefreshCoordinator(reader: reader)
    let context = testKubernetesContext()

    let task = Task {
        await coordinator.fetch(contextID: context.id, context: context, namespace: .namespace("old-namespace"), kind: .pods, bypassCache: false)
    }
    // Wait for the fetch to genuinely be in-flight (reader invoked and parked)
    // before cancelling — a fixed sleep here would race actor/thread-pool
    // scheduling and could pass or fail depending on machine load.
    while await reader.callCount == 0 {
        await Task.yield()
    }
    await coordinator.cancel(contextID: context.id, namespace: .namespace("old-namespace"))
    await reader.release()
    _ = await task.value

    // A namespace switch away from "old-namespace" must not leave a stale entry that
    // a later fetch for the same key would treat as a fresh hit.
    let state = await coordinator.cacheState(contextID: context.id, namespace: .namespace("old-namespace"), kind: .pods)
    assert(state == .miss)
}

func testResourceRefreshCoordinatorRetryBypassesFreshCache() async {
    let reader = CountingResourceReader()
    let coordinator = ResourceRefreshCoordinator(reader: reader)
    let context = testKubernetesContext()

    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .events, bypassCache: false)
    var callCount = await reader.callCount
    assert(callCount == 1)
    // A fresh cache hit would normally short-circuit — Retry must force a live call anyway.
    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .events, bypassCache: true)
    callCount = await reader.callCount
    assert(callCount == 2, "Retry (bypassCache: true) must always invoke a live fetch, even over a fresh cache hit")
}

private func temporarySQLiteCachePath() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ctx-cache-test-\(UUID().uuidString).sqlite3")
}

func testSQLiteResourceCacheStoresAndLoadsByContextNamespaceKind() async {
    let path = temporarySQLiteCachePath()
    defer { try? FileManager.default.removeItem(at: path) }
    let cache = SQLiteResourceCache(path: path)
    let list = KubernetesResourceList(kind: .pods, columns: ["Name"], rows: [KubernetesResourceRow(id: "app/api", cells: ["Name": "api"])], status: .reachable)

    await cache.store(contextID: "ctx-a", namespace: "app", kind: "pods", list: list)
    let loaded = await cache.load(contextID: "ctx-a", namespace: "app", kind: "pods")

    assert(loaded?.rows.first?.id == "app/api")
    let otherNamespace = await cache.load(contextID: "ctx-a", namespace: "other-namespace", kind: "pods")
    assert(otherNamespace == nil, "a different namespace must not share an entry")
    let otherContext = await cache.load(contextID: "ctx-b", namespace: "app", kind: "pods")
    assert(otherContext == nil, "a different context must not share an entry")
}

func testSQLiteResourceCacheClearContextRemovesOnlyThatContext() async {
    let path = temporarySQLiteCachePath()
    defer { try? FileManager.default.removeItem(at: path) }
    let cache = SQLiteResourceCache(path: path)
    let list = KubernetesResourceList(kind: .pods, columns: ["Name"], rows: [], status: .reachable)

    await cache.store(contextID: "ctx-a", namespace: "app", kind: "pods", list: list)
    await cache.store(contextID: "ctx-b", namespace: "app", kind: "pods", list: list)
    await cache.clearContext("ctx-a")

    let clearedContext = await cache.load(contextID: "ctx-a", namespace: "app", kind: "pods")
    assert(clearedContext == nil)
    let untouchedContext = await cache.load(contextID: "ctx-b", namespace: "app", kind: "pods")
    assert(untouchedContext != nil, "clearing one context must not remove another's entries")
}

func testSQLiteResourceCacheRecoversFromACorruptedFile() async {
    let path = temporarySQLiteCachePath()
    defer { try? FileManager.default.removeItem(at: path) }
    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("not a sqlite file, just garbage bytes".utf8).write(to: path)

    let cache = SQLiteResourceCache(path: path)
    let list = KubernetesResourceList(kind: .pods, columns: ["Name"], rows: [KubernetesResourceRow(id: "app/api", cells: ["Name": "api"])], status: .reachable)
    await cache.store(contextID: "ctx-a", namespace: "app", kind: "pods", list: list)
    let loaded = await cache.load(contextID: "ctx-a", namespace: "app", kind: "pods")

    assert(loaded?.rows.first?.id == "app/api", "a corrupted file must be discarded and replaced with a fresh, working database rather than leaving the cache permanently broken")
}

func testSQLiteResourceCachePrunesEntriesOlderThanRetentionWindow() async {
    let path = temporarySQLiteCachePath()
    defer { try? FileManager.default.removeItem(at: path) }

    let oldList = KubernetesResourceList(
        kind: .pods, columns: ["Name"], rows: [KubernetesResourceRow(id: "app/old", cells: ["Name": "old"])],
        status: .reachable, loadedAt: Date().addingTimeInterval(-31 * 24 * 60 * 60)
    )
    let freshList = KubernetesResourceList(
        kind: .pods, columns: ["Name"], rows: [KubernetesResourceRow(id: "app/fresh", cells: ["Name": "fresh"])],
        status: .reachable, loadedAt: Date()
    )
    do {
        let firstLaunch = SQLiteResourceCache(path: path)
        await firstLaunch.store(contextID: "ctx-a", namespace: "app", kind: "pods", list: oldList)
        await firstLaunch.store(contextID: "ctx-a", namespace: "app", kind: "nodes", list: freshList)
    }

    // A fresh instance simulates the next app launch, where retention pruning runs.
    let secondLaunch = SQLiteResourceCache(path: path)
    let prunedEntry = await secondLaunch.load(contextID: "ctx-a", namespace: "app", kind: "pods")
    let keptEntry = await secondLaunch.load(contextID: "ctx-a", namespace: "app", kind: "nodes")

    assert(prunedEntry == nil, "an entry older than the retention window must be pruned on open")
    assert(keptEntry != nil, "a fresh entry must survive retention pruning")
}

func testResourceRefreshCoordinatorHydratesFromDiskAsStaleOnColdStart() async {
    let path = temporarySQLiteCachePath()
    defer { try? FileManager.default.removeItem(at: path) }
    let diskCache = SQLiteResourceCache(path: path)
    let context = testKubernetesContext()
    let oldList = KubernetesResourceList(
        kind: .nodes, columns: ["Name"],
        rows: [KubernetesResourceRow(id: "node-1", cells: ["Name": "node-1"])],
        status: .reachable,
        loadedAt: Date().addingTimeInterval(-3600)
    )
    await diskCache.store(contextID: context.id, namespace: "__all__", kind: "nodes", list: oldList)

    let reader = CountingResourceReader()
    let coordinator = ResourceRefreshCoordinator(reader: reader, staleThreshold: 30, diskCache: diskCache)

    // Nothing in memory yet — this must hydrate from disk (an hour-old entry is
    // definitely past the 30s stale threshold) rather than block on a live call
    // before returning *something* to render.
    let stateBeforeLiveCallLands = await coordinator.cacheState(contextID: context.id, namespace: .allNamespaces, kind: .nodes)
    assert(stateBeforeLiveCallLands == .miss, "cacheState alone doesn't hydrate — only fetch() does")

    let outcome = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: false)
    assert(outcome.cacheStateBeforeFetch == .stale, "disk-hydrated data is old by definition, so it must read as stale, not a fresh hit")
    let callCount = await reader.callCount
    assert(callCount == 1, "a stale (disk-seeded) entry must still trigger exactly one background refresh")
}

func testResourceRefreshCoordinatorWritesSuccessfulFetchesToDisk() async {
    let path = temporarySQLiteCachePath()
    defer { try? FileManager.default.removeItem(at: path) }
    let diskCache = SQLiteResourceCache(path: path)
    let reader = CountingResourceReader()
    let coordinator = ResourceRefreshCoordinator(reader: reader, diskCache: diskCache)
    let context = testKubernetesContext()

    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .events, bypassCache: false)

    // The write-through is fire-and-forget (Task.detached) — give it a moment.
    try? await Task.sleep(nanoseconds: 100_000_000)
    let onDisk = await diskCache.load(contextID: context.id, namespace: "__all__", kind: "events")
    assert(onDisk != nil, "a successful live fetch should be written through to disk")
}

func testKubectlConcurrencyGateSerializesBackgroundFetchesPastTheCap() async {
    let reader = CountingResourceReader()
    await reader.setDelayNanoseconds(60_000_000)
    let gate = KubectlConcurrencyGate(maxConcurrentBackground: 1)
    let coordinator = ResourceRefreshCoordinator(reader: reader, backgroundGate: gate)
    let context = testKubernetesContext()

    let started = Date()
    async let first = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .pods, bypassCache: false, priority: .background)
    async let second = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: false, priority: .background)
    _ = await (first, second)
    let elapsed = Date().timeIntervalSince(started)

    assert(elapsed > 0.1, "two background fetches serialized behind a 1-slot gate should take roughly 2x the single-fetch delay, took \(elapsed)s")
}

func testKubectlConcurrencyGateNeverDelaysActivePriorityFetch() async {
    let reader = CountingResourceReader()
    await reader.setDelayNanoseconds(80_000_000)
    let gate = KubectlConcurrencyGate(maxConcurrentBackground: 1)
    let coordinator = ResourceRefreshCoordinator(reader: reader, backgroundGate: gate)
    let context = testKubernetesContext()

    // Occupy the only background slot first.
    async let backgroundFetch = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .pods, bypassCache: false, priority: .background)
    try? await Task.sleep(nanoseconds: 10_000_000)

    let started = Date()
    _ = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: false, priority: .active)
    let elapsed = Date().timeIntervalSince(started)
    _ = await backgroundFetch

    // A queued wait would take on the order of the remaining background delay
    // *plus* its own (~150ms); bypassing the gate takes roughly its own delay
    // alone (~80ms). Use 600ms to avoid false failures on slow CI runners
    // (GitHub Actions macos-15) while still proving gate bypass occurred.
    assert(elapsed < 0.6, "an .active fetch must never queue behind a full background gate, took \(elapsed)s")
}

func testRelatedPodsMatchesServiceSelectorAgainstPodLabels() {
    let pods = [
        KubernetesResourceRow(id: "app/api-1", cells: ["Name": "api-1", "Labels": "app=api,tier=backend"]),
        KubernetesResourceRow(id: "app/api-2", cells: ["Name": "api-2", "Labels": "app=api,tier=backend"]),
        KubernetesResourceRow(id: "app/worker-1", cells: ["Name": "worker-1", "Labels": "app=worker,tier=backend"])
    ]
    let selector = KubernetesRelatedPods.parseSelector("app=api")
    let related = KubernetesRelatedPods.relatedPods(selector: selector, pods: pods)

    assert(related.map(\.id) == ["app/api-1", "app/api-2"])
}

func testRelatedPodsRequiresEveryEncodedSelectorKeyToMatch() {
    let pods = [
        KubernetesResourceRow(id: "1", cells: ["Labels": "app=api,tier=backend"]),
        KubernetesResourceRow(id: "2", cells: ["Labels": "app=api,tier=frontend"])
    ]
    let selector = KubernetesRelatedPods.parseSelector("app=api,tier=backend")
    let related = KubernetesRelatedPods.relatedPods(selector: selector, pods: pods)

    assert(related.map(\.id) == ["1"], "a multi-key selector must match every key, not just one")
}

func testRelatedPodsEmptySelectorMatchesNothing() {
    let pods = [KubernetesResourceRow(id: "1", cells: ["Labels": "app=api"])]

    assert(KubernetesRelatedPods.parseSelector("").isEmpty)
    assert(KubernetesRelatedPods.relatedPods(selector: [:], pods: pods).isEmpty, "an empty selector must resolve to no related pods, not all pods")
}

func testRelatedPodsIgnoresMalformedSelectorEntries() {
    let selector = KubernetesRelatedPods.parseSelector("app=api,malformed,tier=backend")
    assert(selector == ["app": "api", "tier": "backend"], "a malformed entry should be dropped, not crash or corrupt the rest")
}

func testRelatedPodsSummaryCountsHealthyAndAttentionPods() {
    let pods = [
        KubernetesResourceRow(id: "1", cells: ["Labels": "app=api", "Status": "Running"]),
        KubernetesResourceRow(id: "2", cells: ["Labels": "app=api", "Status": "CrashLoopBackOff"], warning: true),
        KubernetesResourceRow(id: "3", cells: ["Labels": "app=worker", "Status": "Running"])
    ]
    let summary = KubernetesRelatedPods.summary(selector: ["app": "api"], pods: pods)

    assert(summary.total == 2)
    assert(summary.healthy == 1)
    assert(summary.needsAttention == 1)
}

func testPodLogSelectionAutoSelectsOnlyWhenExactlyOnePod() {
    let onePod = [KubernetesResourceRow(id: "app/api", cells: ["Name": "api", "Status": "Running"])]
    let noPods: [KubernetesResourceRow] = []
    let manyPods = [
        KubernetesResourceRow(id: "app/api-1", cells: ["Name": "api-1", "Status": "Running"]),
        KubernetesResourceRow(id: "app/api-2", cells: ["Name": "api-2", "Status": "Running"])
    ]

    assert(PodLogSelection.autoSelectCandidate(from: onePod)?.id == "app/api")
    assert(PodLogSelection.autoSelectCandidate(from: noPods) == nil)
    assert(PodLogSelection.autoSelectCandidate(from: manyPods) == nil, "must never guess between multiple pods")
}

func testPodLogSelectionSortsByStatusPriority() {
    let rows = [
        KubernetesResourceRow(id: "1", cells: ["Name": "completed-pod", "Status": "Succeeded"]),
        KubernetesResourceRow(id: "2", cells: ["Name": "healthy-pod", "Status": "Running"]),
        KubernetesResourceRow(id: "3", cells: ["Name": "pending-pod", "Status": "Pending"]),
        KubernetesResourceRow(id: "4", cells: ["Name": "crashing-pod", "Status": "CrashLoopBackOff"], warning: true)
    ]

    let sorted = PodLogSelection.sortedForPicker(rows).map(\.id)
    assert(sorted == ["2", "4", "3", "1"], "expected Running, then CrashLoop, then Pending, then Succeeded, got \(sorted)")
}

func testPodRowCapturesWorkloadLabelFromOwnerReference() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success(items([
        [
            "metadata": [
                "namespace": "app", "name": "api-7f9c8d6b5-abcde",
                "ownerReferences": [["kind": "ReplicaSet", "name": "api-7f9c8d6b5"]]
            ],
            "status": ["phase": "Running"]
        ],
        [
            "metadata": [
                "namespace": "app", "name": "worker-0",
                "labels": ["app.kubernetes.io/name": "worker"]
            ],
            "status": ["phase": "Running"]
        ]
    ]))
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)
    let list = await reader.list(kind: .pods, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(list.rows[0].cells["Workload"] == "api", "ReplicaSet hash suffix should be stripped back to the Deployment name")
    assert(list.rows[0].cells["Owner"] == "ReplicaSet/api-7f9c8d6b5 -> Deployment/api")
    assert(list.rows[1].cells["Workload"] == "worker")
    assert(list.rows[1].cells["Labels"] == "app.kubernetes.io/name=worker")
}

func testServiceAndWorkloadRowsCaptureSelectorForRelatedPodsDiscovery() async {
    let kubectl = ScriptedKubectl()
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)
    let context = testKubernetesContext()

    kubectl.defaultOutput = .success(items([
        ["metadata": ["namespace": "app", "name": "api"], "spec": ["selector": ["app": "api", "tier": "backend"], "type": "ClusterIP"]]
    ]))
    let services = await reader.list(kind: .services, context: context, namespace: .namespace("app"))
    assert(KubernetesRelatedPods.parseSelector(services.rows[0].cells["Selector"] ?? "") == ["app": "api", "tier": "backend"])

    kubectl.defaultOutput = .success(items([
        ["kind": "Deployment", "metadata": ["namespace": "app", "name": "api"], "spec": ["selector": ["matchLabels": ["app": "api"]]], "status": [:]]
    ]))
    let workloads = await reader.list(kind: .workloads, context: context, namespace: .namespace("app"))
    assert(KubernetesRelatedPods.parseSelector(workloads.rows[0].cells["Selector"] ?? "") == ["app": "api"])

    kubectl.defaultOutput = .success(items([
        ["metadata": ["namespace": "app", "name": "no-selector"], "spec": ["type": "ClusterIP"]]
    ]))
    let noSelector = await reader.list(kind: .services, context: context, namespace: .namespace("app"))
    assert((noSelector.rows[0].cells["Selector"] ?? "").isEmpty, "a Service with no selector must encode as empty, not crash or omit the key")
}

func testKubernetesResourceRowLocalFiltering() {
    let row = KubernetesResourceRow(id: "app/api", cells: [
        "Namespace": "staging-namespace",
        "Name": "api",
        "Status": "CrashLoopBackOff",
        "Node": "node-a"
    ])

    assert(row.matchesFilter("staging-namespace"))
    assert(row.matchesFilter("crashloop"))
    assert(row.matchesFilter("Node node-a"))
    assert(!row.matchesFilter("production-worker"))

    // Case-insensitive, whitespace-trimmed, and an empty filter matches everything.
    assert(row.matchesFilter("API"))
    assert(row.matchesFilter("  api  "))
    assert(row.matchesFilter(""))

    // Kind/labels/age-shaped columns, as used by Workloads and Namespaces rows.
    let workloadRow = KubernetesResourceRow(id: "demo/worker-deploy", cells: [
        "Namespace": "demo",
        "Kind": "Deployment",
        "Name": "worker-deploy",
        "Ready": "2/2"
    ])
    assert(workloadRow.matchesFilter("Deployment"))
    assert(workloadRow.matchesFilter("2/2"))
    assert(!workloadRow.matchesFilter("StatefulSet"))

    let namespaceRow = KubernetesResourceRow(id: "demo-namespace", cells: [
        "Name": "demo-namespace",
        "Status": "Active",
        "Age": "58d",
        "Labels": "2"
    ])
    assert(namespaceRow.matchesFilter("58d"))
    assert(namespaceRow.matchesFilter("Labels 2"))
    assert(!namespaceRow.matchesFilter("120d"))
}

func testKubernetesResourceReaderParsesPodsNodesAndEvents() async {
    let kubectl = ScriptedKubectl()
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    kubectl.defaultOutput = .success(items([
        ["metadata": ["namespace": "app", "name": "api", "creationTimestamp": "2026-01-01T00:00:00Z"], "spec": ["nodeName": "node-1"], "status": ["phase": "Running", "podIP": "10.42.0.12", "qosClass": "Burstable", "containerStatuses": [["ready": true, "restartCount": 1]]]],
        ["metadata": ["namespace": "app", "name": "worker", "creationTimestamp": "2026-01-01T00:00:00Z"], "status": ["phase": "Running", "containerStatuses": [["ready": false, "restartCount": 3, "state": ["waiting": ["reason": "CrashLoopBackOff"]]]]]]
    ]))
    let pods = await reader.list(kind: .pods, context: testKubernetesContext(), namespace: .allNamespaces)
    assert(pods.rows.count == 2)
    assert(pods.columns.contains("Pod IP"))
    assert(pods.columns.contains("QoS"))
    assert(pods.columns.contains("Owner"))
    assert(pods.rows[0].cells["Pod IP"] == "10.42.0.12")
    assert(pods.rows[0].cells["QoS"] == "Burstable")
    assert(pods.rows[1].cells["Status"] == "CrashLoopBackOff")
    assert(pods.rows[1].warning)

    kubectl.defaultOutput = .success(items([
        ["metadata": ["name": "node-1", "creationTimestamp": "2026-01-01T00:00:00Z", "labels": ["node-role.kubernetes.io/worker": ""]], "status": ["conditions": [["type": "Ready", "status": "True"]], "nodeInfo": ["kubeletVersion": "v1.30"], "addresses": [["type": "InternalIP", "address": "10.0.0.1"]]]]
    ]))
    let nodes = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .allNamespaces)
    assert(nodes.rows[0].cells["Ready"] == "Ready")
    assert(nodes.rows[0].cells["Roles"] == "worker")

    kubectl.defaultOutput = .success(items([
        ["metadata": ["namespace": "app", "name": "event-1"], "involvedObject": ["kind": "Pod", "name": "api"], "type": "Warning", "reason": "BackOff", "message": "Back-off restarting", "lastTimestamp": "2026-01-01T00:00:00Z", "count": 2]
    ]))
    let events = await reader.list(kind: .events, context: testKubernetesContext(), namespace: .allNamespaces)
    assert(events.rows[0].warning)
    assert(events.rows[0].cells["Reason"] == "BackOff")
}

func testKubernetesResourceReaderSecretMetadataDoesNotRequestSecretJSON() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("app api-token Opaque 2 5d\n")
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    let secrets = await reader.list(kind: .secretMetadata, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(secrets.rows[0].cells["Name"] == "api-token")
    assert(secrets.rows[0].cells["Keys"] == "2")
    assert(!kubectl.commands[0].arguments.contains("--output=json"))
    assert(!kubectl.commands[0].arguments.contains("-o"))
}

func testKubernetesResourceReaderUsesParseableStdoutAfterTimeout() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .timeoutWithStdout(items([
        ["metadata": ["name": "node-1", "creationTimestamp": "2026-01-01T00:00:00Z"], "status": ["conditions": [["type": "Ready", "status": "True"]], "nodeInfo": ["kubeletVersion": "v1.30"], "addresses": [["type": "InternalIP", "address": "10.0.0.1"]]]]
    ]))
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 20, heavyTimeout: 30)

    let nodes = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(nodes.status == .reachable)
    assert(nodes.rows.count == 1)
    assert(nodes.diagnostic?.category == .success)
    assert(nodes.diagnostic?.stderrSummary.contains("apiVersion") == false)
}

func testKubeConfigAuthPluginDetectorFindsExecCommandForNamedUser() {
    let kubeconfig = """
    apiVersion: v1
    kind: Config
    users:
    - name: arn:aws:eks:eu-west-1:123456789012:cluster/demo
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1beta1
          command: aws
          args:
          - eks
          - get-token
          - --cluster-name
          - demo
    - name: plain-user
      user:
        token: not-a-real-token
    """

    let withExec = KubeConfigAuthPluginDetector.detect(in: kubeconfig, userName: "arn:aws:eks:eu-west-1:123456789012:cluster/demo")
    assert(withExec.hasExecPlugin)
    assert(withExec.command == "aws")

    let withoutExec = KubeConfigAuthPluginDetector.detect(in: kubeconfig, userName: "plain-user")
    assert(!withoutExec.hasExecPlugin)
    assert(withoutExec.command == nil)

    let unknownUser = KubeConfigAuthPluginDetector.detect(in: kubeconfig, userName: "does-not-exist")
    assert(!unknownUser.hasExecPlugin)
}

func testKubernetesTimeoutBucketCandidatesCoverAllFourCases() {
    assert(KubernetesTimeoutBucket.candidates(category: .forbidden, hasExecPlugin: false) == [.rbac])
    assert(KubernetesTimeoutBucket.candidates(category: .unauthorized, hasExecPlugin: false) == [.rbac])
    assert(KubernetesTimeoutBucket.candidates(category: .authPluginFailed, hasExecPlugin: false) == [.kubectlAuth])
    assert(KubernetesTimeoutBucket.candidates(category: .awsSSOExpired, hasExecPlugin: false) == [.kubectlAuth])
    assert(KubernetesTimeoutBucket.candidates(category: .clusterUnreachable, hasExecPlugin: false) == [.clusterAPI])

    // A raw timeout is genuinely ambiguous from outside the kubectl process —
    // every plausible candidate should be listed, not one guessed.
    let timeoutNoExec = KubernetesTimeoutBucket.candidates(category: .timeout, hasExecPlugin: false)
    assert(timeoutNoExec == [.ctxScheduling, .clusterAPI])
    let timeoutWithExec = KubernetesTimeoutBucket.candidates(category: .timeout, hasExecPlugin: true)
    assert(timeoutWithExec == [.ctxScheduling, .kubectlAuth, .clusterAPI])

    assert(KubernetesTimeoutBucket.candidates(category: .success, hasExecPlugin: false) == [.success])
}

func testCredentialPluginExecutableNotFoundIsAuthFailure() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .failure(stderr: "Unable to connect to the server: getting credentials: exec: executable aws not found")

    let summary = await ClusterHealthService(kubectl: kubectl, timeout: 1).overview(for: testKubernetesContext())

    assert(summary.apiStatus == .authPluginFailed)
    assert(summary.diagnostics.first?.category == .authPluginFailed)
    assert(!kubectl.commands.contains { $0.arguments.contains("auth") }, "RBAC must not run when the exec credential plugin cannot start")
}

func testNodesTimeoutStillReportsTimeoutCategoryForLiveDiagnosis() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .timeout
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 1, heavyTimeout: 1)

    let nodes = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(nodes.status == .timeout, "an actual (unparseable) Nodes timeout must classify as .timeout so the live-debug diagnosis fires")
    assert(nodes.diagnostic?.category == .timeout)
    assert(KubernetesTimeoutBucket.candidates(category: nodes.diagnostic?.category ?? .unknown, hasExecPlugin: false).contains(.ctxScheduling))
}

func testNodesSucceedsWellUnderTimeoutWhenSubprocessIsFast() async {
    let kubectl = ScriptedKubectl()
    kubectl.delayNanoseconds = 200_000_000 // 0.2s stand-in for a real ~6-7s read, scaled for test speed
    kubectl.defaultOutput = .success(items([
        ["metadata": ["name": "node-1", "creationTimestamp": "2026-01-01T00:00:00Z"], "status": ["conditions": [["type": "Ready", "status": "True"]]]]
    ]))
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 12, heavyTimeout: 20)

    let started = Date()
    let nodes = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .allNamespaces)
    let elapsed = Date().timeIntervalSince(started)

    assert(nodes.status == .reachable, "a subprocess that finishes well inside the configured timeout must succeed, not be killed early")
    assert(elapsed < 1.0, "must not be held up by anything beyond the subprocess's own delay")
}

func testSuccessfulExitWithUnparseableStdoutIsNotClassifiedAsTimeout() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("this is not valid JSON")
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 12, heavyTimeout: 20)

    let nodes = await reader.list(kind: .nodes, context: testKubernetesContext(), namespace: .allNamespaces)

    assert(nodes.status != .timeout, "a successful exit with unparseable stdout must never be classified as a timeout")
    assert(nodes.status != .reachable, "must also not silently look like an empty successful read")
}

func testActiveNodesRequestPreemptsGatedBackgroundFetchInsteadOfWaiting() async {
    let reader = CountingResourceReader()
    await reader.setDelayNanoseconds(150_000_000)
    let gate = KubectlConcurrencyGate(maxConcurrentBackground: 1)
    let coordinator = ResourceRefreshCoordinator(reader: reader, backgroundGate: gate)
    let context = testKubernetesContext()

    // Fill the only background slot with unrelated work so a naive background
    // fetch for Nodes would have to queue behind it.
    async let occupier = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .pods, bypassCache: false, priority: .background)
    try? await Task.sleep(nanoseconds: 10_000_000)

    // Start a *background* Nodes prefetch — with the gate full, this would sit
    // in the queue if left alone.
    async let backgroundNodes = coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: false, priority: .background)
    try? await Task.sleep(nanoseconds: 10_000_000)

    // Now the user opens the Nodes screen — an .active request for the same key.
    let activeResult = await coordinator.fetch(contextID: context.id, context: context, namespace: .allNamespaces, kind: .nodes, bypassCache: false, priority: .active)

    _ = await (occupier, backgroundNodes)
    let calls = await reader.calls
    let nodeCalls = calls.filter { $0.kind == .nodes }

    assert(activeResult.list.status == .reachable, "the active fetch must still complete successfully")
    assert(nodeCalls.count == 1, "the queued background Nodes fetch must be cancelled so only the active fetch reaches the reader, got \(nodeCalls.count)")
}

func testCancelledFetchIsNotClassifiedAsTimeout() async {
    let kubectl = ScriptedKubectl()
    kubectl.delayNanoseconds = 100_000_000
    kubectl.defaultOutput = .success(emptyItems())
    let reader = KubernetesResourceReader(kubectl: kubectl, defaultTimeout: 12, heavyTimeout: 20)
    let context = testKubernetesContext()

    let task = Task<KubernetesResourceList, Never> {
        await reader.list(kind: .nodes, context: context, namespace: .allNamespaces)
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()
    let result = await task.value

    assert(result.status != .timeout, "a cancelled fetch must never be misreported as a timeout")
}

func testKubernetesResourceDetailIsMetadataOnlyForSecrets() {
    let row = KubernetesResourceRow(id: "demo-namespace/api-token", cells: [
        "Namespace": "demo-namespace",
        "Name": "api-token",
        "Type": "Opaque",
        "Keys": "2",
        "Age": "5d"
    ])

    let detail = KubernetesResourceDetail(kind: .secretMetadata, row: row)

    assert(detail.title == "api-token")
    assert(detail.supportsYAML == false)
    assert(detail.safeReference.contains("api-token"))
    assert(detail.sections.flatMap(\.fields).contains { $0.label == "Keys" && $0.value == "2" })
    assert(!String(describing: detail).localizedCaseInsensitiveContains("password"))
}

func testInspectionYAMLCommandConstruction() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("apiVersion: v1\nkind: Pod\nmetadata:\n  name: demo-pod\n")
    let reader = KubernetesYAMLReader(kubectl: kubectl, timeout: 9)
    let pod = KubernetesResourceRow(id: "demo-namespace/demo-pod", cells: ["Namespace": "demo-namespace", "Name": "demo-pod"])

    let result = await reader.yaml(kind: .pods, row: pod, context: testKubernetesContext())

    assert(result.status == .reachable)
    assert(result.yaml?.contains("demo-pod") == true)
    assert(kubectl.commands[0].arguments.contains("get"))
    assert(kubectl.commands[0].arguments.contains("pod"))
    assert(kubectl.commands[0].arguments.contains("demo-pod"))
    assert(kubectl.commands[0].arguments.contains("--namespace"))
    assert(kubectl.commands[0].arguments.contains("demo-namespace"))
    assert(kubectl.commands[0].arguments.contains("--output=yaml"))
    assert(kubectl.commands[0].arguments.contains("--request-timeout=9s"))
    assert(kubectl.commands[0].environmentOverrides["KUBECONFIG"] == "/tmp/kubeconfig")
}

func testInspectionYAMLUsesResourceRefOverDisplayCells() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("apiVersion: v1\nkind: Pod\nmetadata:\n  name: api\n")
    let context = testKubernetesContext()
    let reader = KubernetesYAMLReader(kubectl: kubectl, timeout: 9)
    let pod = KubernetesResourceRow(
        id: "display/wrong",
        cells: ["Namespace": "display", "Name": "wrong"],
        ref: KubernetesResourceRef(context: context, kind: .pods, namespace: "app", name: "api")
    )

    _ = await reader.yaml(kind: .pods, row: pod, context: context)

    assert(kubectl.commands[0].arguments.contains("api"))
    assert(!kubectl.commands[0].arguments.contains("wrong"))
    assert(kubectl.commands[0].arguments.contains("app"))
    assert(!kubectl.commands[0].arguments.contains("display"))
}

func testInspectionYAMLOmitsNamespaceForClusterScopedResources() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("kind: Node\nmetadata:\n  name: node-a\n")
    let reader = KubernetesYAMLReader(kubectl: kubectl, timeout: 9)
    let node = KubernetesResourceRow(id: "node-a", cells: ["Name": "node-a", "Ready": "Ready"])

    _ = await reader.yaml(kind: .nodes, row: node, context: testKubernetesContext())

    assert(kubectl.commands[0].arguments.contains("node"))
    assert(kubectl.commands[0].arguments.contains("node-a"))
    assert(!kubectl.commands[0].arguments.contains("--namespace"))
}

func testInspectionYAMLDoesNotRequestSecretOrConfigMapValues() async {
    let kubectl = ScriptedKubectl()
    let reader = KubernetesYAMLReader(kubectl: kubectl, timeout: 9)
    let row = KubernetesResourceRow(id: "demo-namespace/app-config", cells: ["Namespace": "demo-namespace", "Name": "app-config"])

    let secret = await reader.yaml(kind: .secretMetadata, row: row, context: testKubernetesContext())
    let configMap = await reader.yaml(kind: .configMaps, row: row, context: testKubernetesContext())

    assert(secret.status == .permissionDenied)
    assert(configMap.status == .permissionDenied)
    assert(kubectl.commands.isEmpty)
}

/// Locks in the exact YAML-availability matrix the UI depends on (disabling the
/// "View YAML" button with a reason, never a silent/broken click): inspection YAML
/// is available for resource kinds with nothing sensitive in their spec, and
/// disabled for kinds that can carry secret values or need redaction rules that
/// don't exist yet.
func testInspectionYAMLAvailabilityMatrix() {
    let expectedAvailable: [KubernetesResourceKind: Bool] = [
        .namespaces: true,
        .nodes: true,
        .pods: true,
        .cronJobs: true,
        .services: true,
        .ingress: true,
        .events: true,
        .hpa: true,
        .pvc: true,
        .workloads: false,
        .configMaps: false,
        .secretMetadata: false
    ]

    for kind in KubernetesResourceKind.allCases {
        guard let expected = expectedAvailable[kind] else {
            assertionFailure("missing YAML-availability expectation for \(kind)")
            continue
        }
        assert(kind.supportsInspectionYAML == expected, "\(kind) expected supportsInspectionYAML == \(expected)")
    }
}

func testKubeConfigMutationServiceAddsContextWithDefaults() async throws {
    let runner = RecordingCloudRunner()
    let service = KubeConfigMutationService(runner: runner)

    try await service.addContext(name: "dev", server: "https://127.0.0.1:6443", cluster: "", user: "", namespace: "apps", token: "demo-token")

    let commands = await runner.allCommands()
    assert(commands == [
        ["kubectl", "config", "set-cluster", "dev-cluster", "--server=https://127.0.0.1:6443", "--insecure-skip-tls-verify=true"],
        ["kubectl", "config", "set-credentials", "dev-user", "--token=demo-token"],
        ["kubectl", "config", "set-context", "dev", "--cluster=dev-cluster", "--user=dev-user", "--namespace=apps"]
    ])
}

func testKubeConfigMutationServiceTargetsGivenKubeconfigPath() async throws {
    let runner = RecordingCloudRunner()
    let service = KubeConfigMutationService(runner: runner)

    // A caller scoped to a non-default kubeconfig (Settings > custom path, or a
    // multi-file KUBECONFIG) must have every mutation explicitly targeted at that
    // file — otherwise kubectl's own default resolution silently writes somewhere
    // the app never reads back from, and the change looks "lost".
    try await service.addContext(
        name: "dev",
        server: "https://127.0.0.1:6443",
        cluster: "",
        user: "",
        namespace: "apps",
        token: "demo-token",
        kubeconfigPath: "/tmp/custom-kubeconfig"
    )

    let commands = await runner.allCommands()
    assert(commands.allSatisfy { $0.count > 2 && $0[1] == "--kubeconfig" && $0[2] == "/tmp/custom-kubeconfig" }, "every kubectl call must be scoped to the caller's kubeconfig path")
}

func testKubeConfigMutationServiceAddsEKSExecCredential() async throws {
    let runner = RecordingCloudRunner()
    let service = KubeConfigMutationService(runner: runner)

    try await service.addContext(
        name: "example-eks",
        server: "https://example.us-east-1.eks.amazonaws.com",
        cluster: "example-eks",
        user: "",
        namespace: "default",
        credential: .awsEKS(region: "us-east-1", profile: "ops-admin")
    )

    let commands = await runner.allCommands()
    assert(commands == [
        ["kubectl", "config", "set-cluster", "example-eks", "--server=https://example.us-east-1.eks.amazonaws.com", "--insecure-skip-tls-verify=true"],
        [
            "kubectl", "config", "set-credentials", "example-eks-user",
            "--exec-command=aws",
            "--exec-api-version=client.authentication.k8s.io/v1beta1",
            "--exec-interactive-mode=Never",
            "--exec-arg=eks",
            "--exec-arg=get-token",
            "--exec-arg=--cluster-name",
            "--exec-arg=example-eks",
            "--exec-arg=--region",
            "--exec-arg=us-east-1",
            "--exec-arg=--profile",
            "--exec-arg=ops-admin"
        ],
        ["kubectl", "config", "set-context", "example-eks", "--cluster=example-eks", "--user=example-eks-user", "--namespace=default"]
    ])
}

func testKubeConfigMutationServiceAddsInternalProxyWithoutUser() async throws {
    let runner = RecordingCloudRunner()
    let service = KubeConfigMutationService(runner: runner)

    try await service.addContext(
        name: "internal-prod",
        server: "https://127.0.0.1:8443",
        cluster: "internal-prod",
        user: "",
        namespace: "default",
        credential: .internalProxy
    )

    let commands = await runner.allCommands()
    assert(commands == [
        ["kubectl", "config", "set-cluster", "internal-prod", "--server=https://127.0.0.1:8443", "--insecure-skip-tls-verify=true"],
        ["kubectl", "config", "set-context", "internal-prod", "--cluster=internal-prod", "--namespace=default"]
    ])
}

func testKubeConfigMutationServiceUpdateClearsNamespaceWhenEmpty() async throws {
    let runner = RecordingCloudRunner()
    let service = KubeConfigMutationService(runner: runner)

    try await service.updateContext(oldName: "old", newName: "new", server: "http://127.0.0.1:8080", cluster: "cluster-a", user: "user-a", namespace: "", token: nil)

    let commands = await runner.allCommands()
    assert(commands == [
        ["kubectl", "config", "rename-context", "old", "new"],
        ["kubectl", "config", "set-cluster", "cluster-a", "--server=http://127.0.0.1:8080"],
        ["kubectl", "config", "set-context", "new", "--cluster=cluster-a", "--user=user-a", "--namespace="]
    ])
}

func testKubeConfigMutationServiceRedactsSensitiveFailureOutput() async {
    let runner = RecordingCloudRunner()
    await runner.setDefault(CommandResult(exitCode: 1, output: "bearer demo-token failed"))
    let service = KubeConfigMutationService(runner: runner)

    do {
        try await service.deleteContext("prod")
        assertionFailure("Expected delete failure")
    } catch {
        let message = error.localizedDescription
        assert(message.contains("[redacted]"))
        assert(!message.contains("demo-token"))
    }
}

func testProfileCommandServiceBuildsProviderCommands() async {
    let runner = RecordingCloudRunner()
    let service = ProfileCommandService(runner: runner)
    let aws = CloudProfile(provider: .aws, name: "dev")
    let gcp = CloudProfile(provider: .gcp, name: "dev", roleName: "dev@example.com")
    let azure = CloudProfile(provider: .azure, name: "dev", accountID: "sub-123", roleName: "tenant-123")
    let kube = CloudProfile(provider: .kubernetes, name: "dev-context")

    _ = await service.activateGCPConfiguration(gcp)
    _ = await service.activateAzureSubscription(azure)
    _ = await service.login(aws)
    _ = await service.login(gcp)
    _ = await service.login(azure)
    _ = await service.selectAzureSubscription(azure)
    _ = await service.logout(aws)
    _ = await service.logout(gcp)
    _ = await service.logout(azure)
    _ = await service.verify(aws, activeKubeContext: "")
    _ = await service.verify(gcp, activeKubeContext: "")
    _ = await service.verify(azure, activeKubeContext: "")
    _ = await service.verify(kube, activeKubeContext: "dev-context")
    _ = await service.exportAWSCredentials(for: aws)

    let commands = await runner.allCommands()
    assert(commands == [
        ["gcloud", "config", "configurations", "activate", "dev"],
        ["az", "account", "set", "--subscription", "sub-123"],
        ["aws", "sso", "login", "--profile", "dev", "--no-browser"],
        ["gcloud", "auth", "login", "--configuration", "dev", "--account", "dev@example.com"],
        ["az", "login", "--tenant", "tenant-123"],
        ["az", "account", "set", "--subscription", "sub-123"],
        ["aws", "sso", "logout", "--profile", "dev"],
        ["gcloud", "auth", "revoke", "dev@example.com"],
        ["az", "logout"],
        ["aws", "sts", "get-caller-identity", "--profile", "dev", "--output", "json"],
        ["gcloud", "auth", "print-access-token", "--configuration", "dev"],
        ["az", "account", "show", "--subscription", "sub-123", "--output", "json"],
        ["kubectl", "get", "--raw=/version", "--context", "dev-context", "--request-timeout=10s"],
        ["aws", "configure", "export-credentials", "--profile", "dev", "--output", "json"]
    ])
}

func testProfileCommandServiceRedactsFailedOutput() async {
    let runner = RecordingCloudRunner()
    await runner.setDefault(CommandResult(exitCode: 1, output: "bearer demo-token failed"))
    let service = ProfileCommandService(runner: runner)

    let result = await service.login(CloudProfile(provider: .aws, name: "dev"))

    assert(result.output.contains("[redacted]"))
    assert(!result.output.contains("demo-token"))
}

func testProfileCommandServiceStrongDMLoginAndVerify() async {
    actor CustomCommandRunner: CloudCommandRunning {
        private var commands: [[String]] = []
        private var results: [CommandResult] = []

        func setResults(_ results: [CommandResult]) {
            self.results = results
        }

        func allCommands() -> [[String]] {
            commands
        }

        func run(_ arguments: [String]) async -> CommandResult {
            commands.append(arguments)
            if !results.isEmpty {
                return results.removeFirst()
            }
            return CommandResult(exitCode: 0, output: "")
        }
    }

    let runner = CustomCommandRunner()
    await runner.setResults([
        CommandResult(exitCode: 0, output: "sdm-context connected"), // sdm status for verify
        CommandResult(exitCode: 0, output: "connect success"), // sdm connect for login
        CommandResult(exitCode: 0, output: "disconnect success") // sdm disconnect for logout
    ])

    let service = ProfileCommandService(runner: runner)
    let sdmKube = CloudProfile(provider: .kubernetes, name: "sdm-context", roleName: ("sdm-" + "user"))

    // Test verify when cluster API succeeds
    let verifyResult = await service.verify(sdmKube, activeKubeContext: "sdm-context")
    assert(verifyResult.exitCode == 0)

    // Test login: runs sdm connect directly
    let loginResult = await service.login(sdmKube)
    assert(loginResult.exitCode == 0)

    // Test logout
    let logoutResult = await service.logout(sdmKube)
    assert(logoutResult.exitCode == 0)

    let commands = await runner.allCommands()
    assert(commands == [
        ["sdm", "status"],
        ["sdm", "connect", "sdm-context"],
        ["sdm", "disconnect", "sdm-context"]
    ])
}

func testCTXUpdateServiceParsesReleaseAndComparesVersions() throws {
    let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.3"])

    assert(CTXUpdateService.releaseTag(from: data) == "v1.2.3")
    assert(CTXUpdateService.isUpdateAvailable(latestTag: "v1.2.3", currentVersion: "1.2.2"))
    assert(!CTXUpdateService.isUpdateAvailable(latestTag: "v1.2.3", currentVersion: "1.2.3"))
    assert(CTXUpdateService.downloadURL(for: "v1.2.3")?.absoluteString == "https://github.com/eliasaf-abargel/CTX/releases/download/v1.2.3/CTX.app.zip")
}

func testAWSSessionExpirationServicePrefersCredentialsExpiry() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-aws-expiry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let credentialsURL = dir.appendingPathComponent("credentials")
    try """
    [dev]
    aws_access_key_id = example
    aws_session_expiration = 2026-07-04T12:34:56Z
    """.write(to: credentialsURL, atomically: true, encoding: .utf8)

    let cacheURL = dir.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    try """
    {"startUrl":"https://example.awsapps.com/start","expiresAt":"2026-07-04T11:00:00Z"}
    """.write(to: cacheURL.appendingPathComponent("cache.json"), atomically: true, encoding: .utf8)

    let service = AWSSessionExpirationService(credentialsURL: credentialsURL, ssoCacheURL: cacheURL)
    let profile = CloudProfile(provider: .aws, name: "dev", ssoStartURL: "https://example.awsapps.com/start")
    let expiry = service.sessionExpiry(for: profile)

    assert(expiry == ISO8601DateFormatter().date(from: "2026-07-04T12:34:56Z"))
}

func testAWSCredentialsFileAuditFlagsConfigKeysThatOverrideTheConfigFile() throws {
    let text = """
    [demo]
    sso_start_url = https://stale.awsapps.com/start
    aws_access_key_id = AKIA
    aws_secret_access_key = secret

    [plain]
    aws_access_key_id = AKIA
    aws_secret_access_key = secret
    aws_session_token = token

    [inherits]
    Role_ARN = arn:aws:iam::111122223333:role/Admin
    """

    let conflicts = AWSCredentialsFileAudit.conflicts(credentialsText: text)
    assert(conflicts.count == 2)
    assert(conflicts[0].profileName == "demo")
    assert(conflicts[0].overridingKeys == ["sso_start_url"])
    // Credentials-only sections are the normal case and must stay quiet — CTX
    // writes them itself after every verified login.
    assert(!conflicts.contains { $0.profileName == "plain" })
    // Key matching is case-insensitive, like the CLI's own parser.
    assert(conflicts[1].overridingKeys == ["role_arn"])
    assert(conflicts[0].explanation.contains("~/.aws/config"))
}

func testCLIToolRequirementsCoverEachProfileShape() throws {
    assert(CLITool.required(for: CloudProfile(provider: .aws, name: "dev")) == [.aws])
    assert(CLITool.required(for: CloudProfile(provider: .gcp, name: "dev")) == [.gcloud])
    assert(CLITool.required(for: CloudProfile(provider: .azure, name: "dev")) == [.az])

    let plainKube = CloudProfile(provider: .kubernetes, name: "dev-context")
    assert(CLITool.required(for: plainKube) == [.kubectl])

    // A broker-fronted context needs its broker's CLI on top of kubectl.
    let sdmKube = CloudProfile(provider: .kubernetes, name: "sdm-cluster", roleName: "sdm-" + "user")
    assert(sdmKube.usesStrongDM ? CLITool.required(for: sdmKube) == [.kubectl, .sdm] : true)

    assert(CLITool.aws.installCommand == "brew install awscli")
    assert(CLITool.gcloud.installCommand == "brew install --cask google-cloud-sdk")
    // StrongDM ships no Homebrew package — the sheet must fall back to its page.
    assert(CLITool.sdm.installCommand == nil)

    assert(CLIToolPaths.resolve("definitely-not-a-real-cli-xyz") == nil)
    assert(CLIToolPaths.resolve("ls") != nil)
    assert(CLIToolPaths.dirs(fromPathVariable: "/a:/b") == ["/a", "/b"])
    assert(CLIToolPaths.searchDirs.contains("/opt/homebrew/bin"))
}

func testAWSSSOTokenStateDistinguishesInteractiveLoginFromSilentRefresh() throws {
    let now = ISO8601DateFormatter().date(from: "2026-08-12T10:00:00Z")!
    let later = now.addingTimeInterval(3600)
    let earlier = now.addingTimeInterval(-3600)

    assert(AWSSessionExpirationService.tokenState(expiresAt: later, refreshToken: nil, registrationExpiresAt: nil, now: now) == .valid(later))
    // Expiring inside the slack window is not "valid".
    assert(AWSSessionExpirationService.tokenState(expiresAt: now.addingTimeInterval(30), refreshToken: "r", registrationExpiresAt: later, now: now) == .refreshable)
    assert(AWSSessionExpirationService.tokenState(expiresAt: earlier, refreshToken: "r", registrationExpiresAt: later, now: now) == .refreshable)
    assert(AWSSessionExpirationService.tokenState(expiresAt: earlier, refreshToken: "r", registrationExpiresAt: earlier, now: now) == .needsInteractive)
    assert(AWSSessionExpirationService.tokenState(expiresAt: earlier, refreshToken: nil, registrationExpiresAt: later, now: now) == .needsInteractive)
    assert(AWSSessionExpirationService.tokenState(expiresAt: nil, refreshToken: nil, registrationExpiresAt: nil, now: now) == .needsInteractive)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-sso-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try """
    {"startUrl":"https://example.awsapps.com/start","expiresAt":"2026-08-12T09:00:00Z","refreshToken":"r","registrationExpiresAt":"2026-11-12T09:00:00Z"}
    """.write(to: dir.appendingPathComponent("token.json"), atomically: true, encoding: .utf8)

    let service = AWSSessionExpirationService(credentialsURL: dir.appendingPathComponent("credentials"), ssoCacheURL: dir)
    let profile = CloudProfile(provider: .aws, name: "dev", ssoStartURL: "https://example.awsapps.com/start")
    assert(service.ssoTokenState(for: profile, now: now) == .refreshable)

    let unknown = CloudProfile(provider: .aws, name: "other", ssoStartURL: "https://other.awsapps.com/start")
    assert(service.ssoTokenState(for: unknown, now: now) == .needsInteractive)
}

func testAWSCredentialServiceParsesIdentityAndCredentials() throws {
    let service = AWSCredentialService()
    let identity = service.identity(fromCallerIdentityOutput: #"{"Arn":"arn:aws:sts::123456789012:assumed-role/Admin/dev@example.com","Account":"123456789012"}"#)
    let exported = try AWSCredentialService.parseExportedCredentials(#"{"AccessKeyId":"AKIAEXAMPLE","SecretAccessKey":"secret","SessionToken":"token","Expiration":"2026-07-04T12:34:56Z"}"#)

    assert(identity == "dev@example.com")
    assert(exported.accessKeyId == "AKIAEXAMPLE")
    assert(exported.secretAccessKey == "secret")
    assert(exported.sessionToken == "token")
    assert(exported.expiration == "2026-07-04T12:34:56Z")
}

func testCloudProfilePersistenceServiceWritesAWSProfile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-persistence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("config")
    let service = CloudProfilePersistenceService(awsConfigURL: configURL)
    var draft = AWSProfileDraft()
    draft.name = "dev"
    draft.ssoStartURL = "https://example.awsapps.com/start"
    draft.ssoRegion = "us-east-1"
    draft.accountID = "123456789012"
    draft.roleName = "Developer"
    draft.defaultRegion = "us-west-2"

    try service.addAWSProfile(draft)
    let added = try String(contentsOf: configURL, encoding: .utf8)
    assert(added.contains("[profile dev]"))
    assert(added.contains("sso_account_id = 123456789012"))

    try service.deleteAWSProfile("dev")
    let deleted = try String(contentsOf: configURL, encoding: .utf8)
    assert(!deleted.contains("[profile dev]"))
}

func testProfileStoreAddsAWSProfileIntoVisibleStateImmediately() async throws {
    try await MainActor.run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("aws-config")
        let credentialsURL = dir.appendingPathComponent("aws-credentials")
        let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
        try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)

        let suiteName = "ctx-profile-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runner = RecordingCloudRunner()
        let store = ProfileStore(
            configURL: configURL,
            runner: runner,
            kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
            profileCommands: ProfileCommandService(runner: runner),
            updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
            awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL),
            profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
            fileWatchers: ProfileFileWatcherService(),
            folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
            startsBackgroundServices: false
        )

        var draft = AWSProfileDraft()
        draft.name = "dev"
        draft.ssoStartURL = "https://example.awsapps.com/start"
        draft.ssoRegion = "us-east-1"
        draft.accountID = "123456789012"
        draft.roleName = "Developer"
        draft.defaultRegion = "us-west-2"

        try store.addAWSProfile(draft)

        assert(store.profiles.contains { $0.provider == .aws && $0.name == "dev" })
        assert(store.selectedProfile?.name == "dev")
        assert(store.activeAWSProfile == "dev")
    }
}

@MainActor
func testProfileStoreAddsCloudProfilesIntoTargetFolders() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-folders-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let oldGCPPath = UserDefaults.standard.string(forKey: "customGCPConfigDirPath")
    let oldAzurePath = UserDefaults.standard.string(forKey: "customAzureProfilesDirPath")
    UserDefaults.standard.set(dir.appendingPathComponent("gcloud").path, forKey: "customGCPConfigDirPath")
    UserDefaults.standard.set(dir.appendingPathComponent("azure").path, forKey: "customAzureProfilesDirPath")
    defer {
        if let oldGCPPath {
            UserDefaults.standard.set(oldGCPPath, forKey: "customGCPConfigDirPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "customGCPConfigDirPath")
        }
        if let oldAzurePath {
            UserDefaults.standard.set(oldAzurePath, forKey: "customAzureProfilesDirPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "customAzureProfilesDirPath")
        }
    }

    let suiteName = "ctx-profile-folders-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let runner = RecordingCloudRunner()
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(
        configURL: dir.appendingPathComponent("aws-config"),
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: dir.appendingPathComponent("aws-config"), credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: dir.appendingPathComponent("aws-config")),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    var aws = AWSProfileDraft()
    aws.name = " cloud-alpha "
    aws.ssoStartURL = "https://example.awsapps.com/start"
    aws.ssoRegion = "us-east-1"
    aws.accountID = "123456789012"
    aws.roleName = "Developer"
    aws.defaultRegion = "us-west-2"
    try store.addAWSProfile(aws, targetFolder: CloudFolder.builtIn(provider: .aws, environment: .data))

    var gcp = GCPProfileDraft()
    gcp.name = " cloud-beta "
    gcp.project = "example-project-123456"
    gcp.account = "user@example.com"
    try store.addGCPProfile(gcp, targetFolder: CloudFolder.builtIn(provider: .gcp, environment: .development))

    var azure = AzureProfileDraft()
    azure.name = " cloud-gamma "
    azure.subscriptionID = "00000000-0000-0000-0000-000000000000"
    try store.addAzureProfile(azure, targetFolder: CloudFolder.builtIn(provider: .azure, environment: .production))

    assert(store.folderOverrides["AWS:cloud-alpha"] == "AWS:Data")
    assert(store.folderOverrides["GCP:cloud-beta"] == "GCP:Development")
    assert(store.folderOverrides["Azure:cloud-gamma"] == "Azure:Production")
}

@MainActor
func testProfileStoreKeepsKubeContextTargetFolderBeforeDiscoveryCatchesUp() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-folder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("aws-config")
    let credentialsURL = dir.appendingPathComponent("aws-credentials")
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-folder-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    let targetFolder = CloudFolder.builtIn(provider: .kubernetes, environment: .development)

    try await store.addKubeContext(
        name: " internal-dev ",
        server: " https://127.0.0.1:8443 ",
        cluster: " internal-dev ",
        user: "",
        namespace: "default",
        credential: .internalProxy,
        targetFolder: targetFolder
    )

    assert(store.folderOverrides["Kubernetes:internal-dev"] == targetFolder.id)
    assert(CloudFolderPreferencesStore(defaults: defaults).load().folderOverrides["Kubernetes:internal-dev"] == targetFolder.id)
}

@MainActor
func testProfileStorePromptsForFolderWhenCreatedWithoutOne() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-folder-prompt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("aws-config")
    let credentialsURL = dir.appendingPathComponent("aws-credentials")
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-folder-prompt-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    assert(store.pendingFolderPrompt == nil, "no prompt before anything is created")

    var aws = AWSProfileDraft()
    aws.name = "unfiled-profile"
    aws.ssoStartURL = "https://example.awsapps.com/start"
    aws.ssoRegion = "us-east-1"
    aws.accountID = "123456789012"
    aws.roleName = "Developer"
    aws.defaultRegion = "us-west-2"

    // Created with no targetFolder — must prompt for one instead of silently
    // landing in the generic default folder.
    try store.addAWSProfile(aws)
    // Generous: this waits on a detached Task scheduling a subprocess call, which can
    // take well over a second on a loaded machine. A tight deadline here fails as a
    // wrong-kubeconfig assertion rather than as the timeout it actually is.
    let deadline = Date().addingTimeInterval(10)
    while store.pendingFolderPrompt == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    assert(store.pendingFolderPrompt?.name == "unfiled-profile", "must offer a folder for a profile created outside any folder")

    store.pendingFolderPrompt = nil

    var filed = AWSProfileDraft()
    filed.name = "filed-profile"
    filed.ssoStartURL = "https://example.awsapps.com/start"
    filed.ssoRegion = "us-east-1"
    filed.accountID = "123456789012"
    filed.roleName = "Developer"
    filed.defaultRegion = "us-west-2"

    // Created with an explicit targetFolder — must not prompt again.
    try store.addAWSProfile(filed, targetFolder: CloudFolder.builtIn(provider: .aws, environment: .data))
    try await Task.sleep(nanoseconds: 300_000_000)
    assert(store.pendingFolderPrompt == nil, "must not prompt when a folder was already chosen at creation time")
}

@MainActor
func testProfileStoreTargetsContextsOwnKubeconfigFileNotJustThePrimaryOne() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-logout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Two-file KUBECONFIG where the context under test lives only in the SECOND
    // file — the primary/first candidate path has no contexts at all. Any call
    // that falls back to "the primary path" instead of resolving this context's
    // actual file would silently operate on the wrong (empty) file.
    let primary = dir.appendingPathComponent("primary")
    let secondary = dir.appendingPathComponent("secondary")
    try "apiVersion: v1\nkind: Config\n".write(to: primary, atomically: true, encoding: .utf8)
    try kubeconfig(context: "team-b", cluster: "team-b-cluster", user: "team-b-user", server: "https://team-b.example.com:6443")
        .write(to: secondary, atomically: true, encoding: .utf8)

    let env = ["KUBECONFIG": "\(primary.path):\(secondary.path)"]
    let suiteName = "ctx-kube-logout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { env }, customPath: { nil }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    guard let profile = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == "team-b" }) else {
        assertionFailure("expected discovery to find the team-b context")
        return
    }

    store.logout(profile)
    // Generous: this waits on a detached Task scheduling a subprocess call, which can
    // take well over a second on a loaded machine. A tight deadline here fails as a
    // wrong-kubeconfig assertion rather than as the timeout it actually is.
    let deadline = Date().addingTimeInterval(10)
    while (await runner.allCommands()).isEmpty, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let commands = await runner.allCommands()
    assert(Array(commands.first?.dropFirst(1).prefix(2) ?? []) == ["--kubeconfig", secondary.path], "logout must target the file the context actually lives in, not the primary KUBECONFIG entry")

    _ = await store.resolveKubeServer(for: "team-b-cluster", contextName: "team-b")
    let resolveCommands = await runner.allCommands()
    assert(Array(resolveCommands.last?.dropFirst(1).prefix(2) ?? []) == ["--kubeconfig", secondary.path], "resolving the server for an existing context's edit form must target that context's own file, not the primary KUBECONFIG entry")
}

@MainActor
func testProfileStoreLoginActuallySwitchesKubeContextEvenWhenStatusWasUnknown() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-login-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(context: "team-c", cluster: "team-c-cluster", user: "team-c-user", server: "https://team-c.example.com:6443")
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-login-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        // What this test proves is the context switch, not whether the host has
        // kubectl. Left to the real preflight it passes on a developer Mac and
        // fails on a CI runner without kubectl, where `login()` returns early.
        missingCLIToolResolver: { _ in nil },
        // Mirrors real app startup: contexts are discovered before the background
        // verify pass has run, so a never-yet-verified context sits at `.unknown` —
        // exactly the state that used to make `login()` skip the real context switch.
        startsBackgroundServices: false
    )

    guard let profile = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == "team-c" }) else {
        assertionFailure("expected discovery to find the team-c context")
        return
    }
    assert(profile.status == .unknown, "test only proves what it claims if the profile truly starts unverified")

    store.login(profile)
    // Generous: this waits on a detached Task scheduling a subprocess call, which can
    // take well over a second on a loaded machine. A tight deadline here fails as a
    // wrong-kubeconfig assertion rather than as the timeout it actually is.
    let deadline = Date().addingTimeInterval(10)
    while !(await runner.allCommands()).contains(where: { $0.contains("use-context") }), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let commands = await runner.allCommands()
    assert(commands.contains { $0.contains("use-context") && $0.contains("team-c") }, "Connect on a never-yet-verified kube context must still run the real kubectl context switch, not just update in-app bookkeeping")
}

/// The other side of the injected preflight: a resolver that does report a missing
/// tool must still stop the connect before any command runs, so making the switch
/// test host-independent cannot quietly disable the preflight itself.
@MainActor
func testProfileStoreLoginStopsAtPreflightWhenARequiredCLIIsMissing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-preflight-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(context: "team-d", cluster: "team-d-cluster", user: "team-d-user", server: "https://team-d.example.com:6443")
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-preflight-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: { _ in .kubectl },
        startsBackgroundServices: false
    )

    guard let profile = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == "team-d" }) else {
        assertionFailure("expected discovery to find the team-d context")
        return
    }

    store.login(profile)
    assert(store.missingCLITool?.tool == .kubectl, "a missing required CLI must surface as an install request, not a failed login")
    assert(store.missingCLITool?.profile.id == profile.id, "the install request must name the profile the user tried to connect")

    // Long enough that a connect Task, had one been spawned, would have recorded
    // its command by now.
    try await Task.sleep(nanoseconds: 300_000_000)
    let commands = await runner.allCommands()
    assert(!commands.contains { $0.contains("use-context") }, "a blocked preflight must run no provider commands at all")
}

func testCloudFolderPreferencesStoreRoundTripsState() throws {
    let suiteName = "ctx-folder-prefs-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        assertionFailure("Could not create test defaults")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = CloudFolderPreferencesStore(defaults: defaults)
    let custom = CloudFolder(id: "AWS:custom:team", provider: .aws, name: "Team", icon: .shield)
    let builtIn = CloudFolder(id: "AWS:Production", provider: .aws, name: "Prod", icon: .server, isCustom: false)

    store.saveCustomFolders([custom])
    store.saveFolderCustomizations([builtIn.id: builtIn])
    store.saveFolderOverrides(["AWS:dev": custom.id])
    store.saveHiddenFolderIDs([CloudFolder.builtIn(provider: .aws, environment: .other).id])

    let state = store.load()
    assert(state.customFolders == [custom])
    assert(state.folderCustomizations[builtIn.id] == builtIn)
    assert(state.folderOverrides["AWS:dev"] == custom.id)
    assert(state.hiddenFolderIDs == ["AWS:Other"])
}

func testOpenSourceFixturesStayGeneric() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    // Directories, not a list of filenames: the previous version named each doc
    // individually, so moving or adding one silently dropped it from the scan.
    let scannedPaths = [
        root.appendingPathComponent("Sources"),
        root.appendingPathComponent("docs"),
        root.appendingPathComponent("README.md"),
        root.appendingPathComponent("AGENTS.md")
    ]
    let blocked = [
        ["access", "hub"],
        ["monitoring", "-", "prod"],
        ["ip", "-", "10"],
        ["j", "frog"],
        ["AWS", "-", "it", "-", "admin"],
        ["it", "services"],
        ["s", "d", "m", "-", "user"],
        ["it", "-", "admin"],
        ["sell", "er"],
        ["p", "2", "p"],
        ["s", "d", "m", "-", "prod"]
    ].map { $0.joined() }

    for path in scannedPaths where FileManager.default.fileExists(atPath: path.path) {
        for file in try textFiles(under: path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in blocked {
                assert(!text.localizedCaseInsensitiveContains(token), "Private fixture token \(token) found in \(file.path)")
            }
        }
    }
}

func testLocalAuditLogRedactsSensitiveMessages() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("audit.jsonl")
    let audit = LocalAuditLogService(fileURL: url)
    try audit.record(AuditEvent(type: .kubectlCommandFailed, contextName: "prod", message: "bearer token leaked"))

    let text = try String(contentsOf: url, encoding: .utf8)
    assert(text.contains("[redacted]"))
    assert(!text.localizedCaseInsensitiveContains("bearer token leaked"))
}

/// Fake `KubernetesResourceReading` for `ResourceRefreshCoordinator` tests — counts
/// live calls, records their keys, and can simulate a slow response (to test
/// dedup of concurrent requests) or a scripted result (to test failure handling).
actor CountingResourceReader: KubernetesResourceReading {
    private(set) var callCount = 0
    private(set) var calls: [(contextID: String, namespace: String, kind: KubernetesResourceKind)] = []
    private var resultProvider: (KubernetesResourceKind, KubernetesNamespaceSelection) -> KubernetesResourceList = { kind, _ in
        KubernetesResourceList(kind: kind, columns: [], rows: [], status: .reachable)
    }
    private var delayNanoseconds: UInt64 = 0
    private var holdUntilReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func setDelayNanoseconds(_ value: UInt64) {
        delayNanoseconds = value
    }

    func setResultProvider(_ provider: @escaping (KubernetesResourceKind, KubernetesNamespaceSelection) -> KubernetesResourceList) {
        resultProvider = provider
    }

    /// Makes `list(...)` block right after recording the call, until `release()` is
    /// called — so a test can deterministically act while a fetch is in-flight
    /// instead of racing a fixed `Task.sleep` against actor/thread-pool scheduling.
    func setHoldUntilReleased(_ value: Bool) {
        holdUntilReleased = value
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func list(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection) async -> KubernetesResourceList {
        callCount += 1
        calls.append((context.id, namespace.storageValue, kind))
        if holdUntilReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        let delay = delayNanoseconds
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return resultProvider(kind, namespace)
    }
}

actor RecordingCloudRunner: CloudCommandRunning {
    private var commands: [[String]] = []
    private var defaultResult = CommandResult(exitCode: 0, output: "")

    func setDefault(_ result: CommandResult) {
        defaultResult = result
    }

    func allCommands() -> [[String]] {
        commands
    }

    func run(_ arguments: [String]) async -> CommandResult {
        commands.append(arguments)
        return defaultResult
    }
}

final class ScriptedKubectl: KubectlRunning, KubectlCommandBuilding, KubectlProcessStarting, @unchecked Sendable {
    enum Output {
        case success(String)
        case failure(stderr: String)
        case timeout
        case timeoutWithStdout(String)
    }

    var commands: [KubectlCommand] = []
    var startedCommands: [KubectlCommand] = []
    var outputs: [String: Output] = [:]
    var defaultOutput: Output = .success(emptyItems())
    var error: Error?
    var processToStart: FakeKubectlProcess = FakeKubectlProcess()
    /// Simulates a real subprocess taking measurable time — needed to create a
    /// window in which a caller can be cancelled mid-flight, or to prove a
    /// genuinely-fast command isn't held up by anything on CTX's side.
    var delayNanoseconds: UInt64 = 0
    private let queue = DispatchQueue(label: "ctx.tests.scripted-kubectl")

    func inspectionCommand(context: String, arguments: [String]) throws -> KubectlCommand {
        if let error { throw error }
        return KubectlCommand(executablePath: "/mock/kubectl", arguments: ["--context", context] + arguments)
    }

    func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult {
        let key = command.arguments.dropFirst(2).filter { $0 != "--kubeconfig" && !$0.hasPrefix("/") }.joined(separator: " ")
        let output = queue.sync { () -> Output in
            commands.append(command)
            return outputs[key] ?? defaultOutput
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        switch output {
        case .success(let stdout):
            return KubectlResult(exitCode: 0, stdout: stdout, stderr: "")
        case .failure(let stderr):
            return KubectlResult(exitCode: 1, stdout: "", stderr: stderr)
        case .timeout:
            return KubectlResult(exitCode: 1, stdout: "", stderr: "timed out", timedOut: true)
        case .timeoutWithStdout(let stdout):
            return KubectlResult(exitCode: 1, stdout: stdout, stderr: "timed out", timedOut: true)
        }
    }

    func start(_ command: KubectlCommand) throws -> any KubectlProcessHandling {
        if let error { throw error }
        queue.sync {
            startedCommands.append(command)
        }
        return processToStart
    }
}

final class FakeKubectlProcess: KubectlProcessHandling, @unchecked Sendable {
    var running = true
    var terminated = false
    var output = ""

    private var terminationHandler: (@Sendable () -> Void)?

    var isRunning: Bool {
        running && !terminated
    }

    func terminate() {
        terminated = true
        terminationHandler?()
    }

    func outputIfExited() -> String {
        output
    }

    func setTerminationHandler(_ handler: @Sendable @escaping () -> Void) {
        terminationHandler = handler
        if !isRunning {
            handler()
        }
    }
}

func testKubernetesContext() -> KubernetesContextProfile {
    KubernetesContextProfile(
        contextName: "prod-context",
        clusterName: "prod-cluster",
        userName: "prod-user",
        namespace: "platform",
        kubeconfigPath: "/tmp/kubeconfig",
        providerType: .eks,
        environmentDetection: EnvironmentDetectionResult(type: .production, confidence: 1, source: "test"),
        isCurrent: true
    )
}

func emptyItems() -> String {
    #"{"items":[]}"#
}

func items(_ values: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["items": values])
    return String(decoding: data, as: UTF8.self)
}

func textFiles(under url: URL) throws -> [URL] {
    if url.pathExtension == "md" || url.pathExtension == "swift" {
        return [url]
    }
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }
    return try enumerator.compactMap { item in
        guard let file = item as? URL else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        return file.pathExtension == "swift" || file.pathExtension == "md" ? file : nil
    }
}

func kubeconfig(
    context: String,
    cluster: String,
    user: String,
    namespace: String = "",
    server: String
) -> String {
    """
    apiVersion: v1
    kind: Config
    current-context: \(context)
    clusters:
    - name: \(cluster)
      cluster:
        server: \(server)
    contexts:
    - name: \(context)
      context:
        cluster: \(cluster)
        user: \(user)
    \(namespace.isEmpty ? "" : "    namespace: \(namespace)")
    users:
    - name: \(user)
      user: {}
    """
}

testProviderLabelsStayCloudSpecific()
testEnvironmentInferencePrefersSpecificProfileSignals()
testBuiltInFolderIdentityIsStable()
testAWSDraftDuplicatePreservesConfigurationAndRenamesCopy()
testKubernetesContextProfileMapsToCloudProfile()
testEnvironmentDetection()
testKubernetesProviderDetection()
try testKubeConfigDiscoverySingleFile()
try testKubeConfigDiscoveryHandlesNameAfterNestedClusterOrContextKey()
try testKubeConfigDiscoveryUsesKubeconfigMultipath()
try testKubeConfigDiscoveryCustomPathOverridesKubeconfig()
try testKubeConfigDiscoveryDeduplicatesContextNames()
try testKubeConfigDiscoveryHandlesInvalidFiles()
try testLocalProfileDiscoveryLoadsAWSAndKubernetesProfiles()
try testKubectlCommandConstruction()
try await testKubectlRunnerAddsCliSearchPathToChildEnvironment()
await testPortForwardBuildsSafeServiceCommand()
await testPortForwardRejectsInvalidPortsBeforeStartingProcess()
await testPortForwardStopTerminatesProcess()
await testClusterOverviewMapsInspectionSummaries()
await testClusterOverviewMapsRBACDeniedAndPermissionDenied()
testWorkloadsSummaryCountsWarningsAsUnhealthy()
testPodsSummaryCountsStatusBuckets()
testServiceAndIngressSummariesCaptureEndpointVisibility()
await testIngressRowsCaptureBackendServicesForTopology()
testEventsSummaryCapturesLatestWarningTimelineSignal()
testEventObjectTargetParsesKnownResourceKinds()
await testClusterOverviewMapsTimeoutUnauthorizedAndMissingKubectl()
await testClusterOverviewPreservesContextAndKubeconfig()
await testClusterOverviewMapsContextMissingAndLocalProxyRefused()
await testClusterOverviewMapsRBACDeniedStates()
await testClusterOverviewDoesNotReadSecretValues()
await testKubernetesResourceReaderParsesNamespaces()
await testKubernetesResourceReaderAttachesResourceRefs()
await testNodesAreClusterScopedRegardlessOfNamespaceSelection()
await testKubernetesResourceReaderUsesNamespaceScopes()
await testResourceRefreshCoordinatorCachesPerNamespaceScope()
await testResourceRefreshCoordinatorIsolatesContexts()
await testResourceRefreshCoordinatorDeduplicatesConcurrentFetches()
await testResourceRefreshCoordinatorPreservesGoodDataOnFailedRefresh()
await testResourceRefreshCoordinatorCancelDropsInFlightRequest()
await testResourceRefreshCoordinatorRetryBypassesFreshCache()
await testSQLiteResourceCacheStoresAndLoadsByContextNamespaceKind()
await testSQLiteResourceCacheClearContextRemovesOnlyThatContext()
await testSQLiteResourceCacheRecoversFromACorruptedFile()
await testSQLiteResourceCachePrunesEntriesOlderThanRetentionWindow()
await testResourceRefreshCoordinatorHydratesFromDiskAsStaleOnColdStart()
await testResourceRefreshCoordinatorWritesSuccessfulFetchesToDisk()
await testKubectlConcurrencyGateSerializesBackgroundFetchesPastTheCap()
await testKubectlConcurrencyGateNeverDelaysActivePriorityFetch()
testKubernetesResourceRowLocalFiltering()
testRelatedPodsMatchesServiceSelectorAgainstPodLabels()
testRelatedPodsRequiresEveryEncodedSelectorKeyToMatch()
testRelatedPodsEmptySelectorMatchesNothing()
testRelatedPodsIgnoresMalformedSelectorEntries()
testRelatedPodsSummaryCountsHealthyAndAttentionPods()
testPodLogSelectionAutoSelectsOnlyWhenExactlyOnePod()
testPodLogSelectionSortsByStatusPriority()
await testPodRowCapturesWorkloadLabelFromOwnerReference()
await testServiceAndWorkloadRowsCaptureSelectorForRelatedPodsDiscovery()
await testKubernetesResourceReaderParsesPodsNodesAndEvents()
await testKubernetesResourceReaderSecretMetadataDoesNotRequestSecretJSON()
await testKubernetesResourceReaderUsesParseableStdoutAfterTimeout()
testKubeConfigAuthPluginDetectorFindsExecCommandForNamedUser()
testKubernetesTimeoutBucketCandidatesCoverAllFourCases()
await testCredentialPluginExecutableNotFoundIsAuthFailure()
await testNodesTimeoutStillReportsTimeoutCategoryForLiveDiagnosis()
await testNodesSucceedsWellUnderTimeoutWhenSubprocessIsFast()
await testSuccessfulExitWithUnparseableStdoutIsNotClassifiedAsTimeout()
await testActiveNodesRequestPreemptsGatedBackgroundFetchInsteadOfWaiting()
await testCancelledFetchIsNotClassifiedAsTimeout()
try testLocalAuditLogRedactsSensitiveMessages()
testKubernetesResourceDetailIsMetadataOnlyForSecrets()
await testInspectionYAMLCommandConstruction()
await testInspectionYAMLUsesResourceRefOverDisplayCells()
await testInspectionYAMLOmitsNamespaceForClusterScopedResources()
await testInspectionYAMLDoesNotRequestSecretOrConfigMapValues()
testInspectionYAMLAvailabilityMatrix()
try await testKubeConfigMutationServiceAddsContextWithDefaults()
try await testKubeConfigMutationServiceTargetsGivenKubeconfigPath()
try await testKubeConfigMutationServiceAddsEKSExecCredential()
try await testKubeConfigMutationServiceAddsInternalProxyWithoutUser()
try await testKubeConfigMutationServiceUpdateClearsNamespaceWhenEmpty()
await testKubeConfigMutationServiceRedactsSensitiveFailureOutput()
await testProfileCommandServiceBuildsProviderCommands()
await testProfileCommandServiceRedactsFailedOutput()
await testProfileCommandServiceStrongDMLoginAndVerify()
try testCTXUpdateServiceParsesReleaseAndComparesVersions()
try testAWSSessionExpirationServicePrefersCredentialsExpiry()
try testAWSCredentialsFileAuditFlagsConfigKeysThatOverrideTheConfigFile()
try testCLIToolRequirementsCoverEachProfileShape()
try testAWSSSOTokenStateDistinguishesInteractiveLoginFromSilentRefresh()
try testAWSCredentialServiceParsesIdentityAndCredentials()
try testCloudProfilePersistenceServiceWritesAWSProfile()
try await testProfileStoreAddsAWSProfileIntoVisibleStateImmediately()
try testProfileStoreAddsCloudProfilesIntoTargetFolders()
try await testProfileStoreKeepsKubeContextTargetFolderBeforeDiscoveryCatchesUp()
try await testProfileStorePromptsForFolderWhenCreatedWithoutOne()
try await testProfileStoreTargetsContextsOwnKubeconfigFileNotJustThePrimaryOne()
try await testProfileStoreLoginActuallySwitchesKubeContextEvenWhenStatusWasUnknown()
try await testProfileStoreLoginStopsAtPreflightWhenARequiredCLIIsMissing()
@MainActor
func testKubernetesContextStatusUpdatesOnVerificationFailureAndExpiration() async throws {
    let store = ProfileStore(startsBackgroundServices: false)
    store.markKubernetesContextNeedsLogin(contextName: "non-existent-context", reason: "API Down")
}

try await testKubernetesContextStatusUpdatesOnVerificationFailureAndExpiration()
func testHPAAndPVCResourceKinds() throws {
    assert(KubernetesResourceKind.hpa.title == "HPA")
    assert(KubernetesResourceKind.pvc.title == "Storage (PVC)")
    assert(KubernetesResourceKind.hpa.supportsInspectionYAML)
    assert(KubernetesResourceKind.pvc.supportsInspectionYAML)
}

try testHPAAndPVCResourceKinds()
try testCloudFolderPreferencesStoreRoundTripsState()
try testOpenSourceFixturesStayGeneric()

// MARK: - Phase 1: hangs, watchers, and command safety

/// A provider CLI that never returns used to leave the profile stuck on
/// "connecting" for the lifetime of the app, with no way to cancel it.
func testCloudCommandRunnerTerminatesAHangingProcess() async throws {
    let started = Date()
    let result = await CloudCommandRunner().run(["sleep", "30"], timeout: 1.0, onOutput: nil)
    let elapsed = Date().timeIntervalSince(started)
    assert(result.exitCode == 124, "expected timeout exit code, got \(result.exitCode)")
    assert(result.output.contains("timed out"), "timeout should be visible in the output")
    assert(elapsed < 10, "runner should return near the timeout, took \(elapsed)s")
}

/// Cancelling the task must actually kill the subprocess, not just abandon it.
func testCloudCommandRunnerCancellationTerminatesTheSubprocess() async throws {
    let started = Date()
    let task = Task {
        await CloudCommandRunner().run(["sleep", "30"], timeout: 0, onOutput: nil)
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    _ = await task.value
    let elapsed = Date().timeIntervalSince(started)
    assert(elapsed < 10, "cancellation should end the run promptly, took \(elapsed)s")
}

/// The regression that made CTX stop noticing CLI logins: every tool CTX watches
/// writes atomically (temp file + rename), which unlinks the inode the watcher
/// holds. Without re-arming, only the first write is ever seen.
func testProfileFileWatcherSurvivesAtomicReplacement() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-watch-\(UUID().uuidString)")
    // The watched file lives in its own directory, and every *other* configured
    // path points somewhere else entirely — otherwise a directory watcher would
    // fire on the temp files an atomic write creates, and the test would pass even
    // with a dead file watcher.
    let watchedDirectory = root.appendingPathComponent("watched")
    let unrelated = root.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: watchedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let target = watchedDirectory.appendingPathComponent("config")
    try "first".write(to: target, atomically: false, encoding: .utf8)

    let counter = FireCounter()
    let watcher = ProfileFileWatcherService()
    watcher.start(
        kubeConfigPath: nil,
        awsConfigPath: target.path,
        gcpActiveConfigPath: unrelated.appendingPathComponent("active_config").path,
        gcpConfigsDirPath: unrelated.appendingPathComponent("configurations").path,
        azureProfilesDirPath: unrelated.appendingPathComponent("azure").path,
        onRefresh: { counter.fire() },
        onGCPActiveConfigChanged: {}
    )
    defer { watcher.stop() }

    // `atomically: true` is exactly what the provider CLIs do — write a temp file
    // and rename it over the target.
    for text in ["second", "third"] {
        try await Task.sleep(nanoseconds: 700_000_000)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }
    try await Task.sleep(nanoseconds: 700_000_000)

    assert(counter.count >= 2, "watcher went deaf after the first atomic replace (fired \(counter.count) times)")
}

final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func fire() {
        lock.lock(); stored += 1; lock.unlock()
    }
}

/// Remediation commands are built from names CTX does not control, including a
/// word sliced out of CLI error output — they must never reach AppleScript's
/// `do script` with shell metacharacters intact.
func testShellCommandSafetyRejectsInjection() throws {
    assert(ShellCommandSafety.isSafeForTerminal("aws sso login --profile dev-sso"))
    assert(ShellCommandSafety.isSafeForTerminal("kubectl get --raw=/version --context my-cluster"))
    assert(ShellCommandSafety.isSafeForTerminal("sdm connect prod-db.example.com"))

    assert(!ShellCommandSafety.isSafeForTerminal("aws sso login --profile a\"; rm -rf ~; echo \""))
    assert(!ShellCommandSafety.isSafeForTerminal("sdm connect $(whoami)"))
    assert(!ShellCommandSafety.isSafeForTerminal("tsh kube login a`id`"))
    assert(!ShellCommandSafety.isSafeForTerminal("aws sso login --profile x && curl evil.test"))
    assert(!ShellCommandSafety.isSafeForTerminal("aws sso login\nrm -rf ~"))
    assert(!ShellCommandSafety.isSafeForTerminal(""))
}

// MARK: - GitOps and Helm read real controller state

func jsonItems(_ text: String) throws -> [[String: Any]] {
    let data = Data(text.utf8)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (root?["items"] as? [[String: Any]]) ?? []
}

/// An ArgoCD Application whose source is a *Git repository*. `targetRevision` is a
/// branch, and the deployed revision is a commit SHA that must be shortened, not
/// shown in full or replaced with the branch name.
func testArgoCDGitBackedApplicationReportsRealFields() throws {
    let items = try jsonItems("""
    {"items":[{
      "metadata":{"name":"checkout","namespace":"argocd","creationTimestamp":"2024-01-02T10:00:00Z"},
      "spec":{"source":{"repoURL":"https://git.example.com/org/platform.git","path":"apps/checkout","targetRevision":"release-2.4"}},
      "status":{"sync":{"status":"OutOfSync","revision":"9f3c1ab7de5544aa10bb2231cc99887766554433"},
                "health":{"status":"Degraded"}}
    }]}
    """)
    let apps = KubernetesGitOpsService.parseArgoCDApplications(items)
    assert(apps.count == 1)
    let app = apps[0]
    assert(app.provider == "ArgoCD" && app.kind == "Application")
    assert(app.sourceKind == .git, "git source misclassified as \(app.sourceKind.rawValue)")
    assert(app.repoURL == "https://git.example.com/org/platform.git")
    assert(app.path == "apps/checkout")
    assert(app.targetRevision == "release-2.4")
    assert(app.syncedRevision == "9f3c1ab", "expected shortened SHA, got \(app.syncedRevision)")
    assert(app.syncStatus == "OutOfSync", "sync status must not be defaulted to Synced")
    assert(app.healthStatus == "Degraded")
    assert(app.chart == KubernetesGitOpsService.unknownValue)
}

/// The case the dashboard used to flatten: an ArgoCD Application that deploys a
/// Helm chart straight from a chart repository. `repoURL` is a chart repo, not Git,
/// and `targetRevision` is the *chart version*.
func testArgoCDHelmChartApplicationIsIdentifiedAsAChart() throws {
    let items = try jsonItems("""
    {"items":[{
      "metadata":{"name":"kube-prometheus-stack","namespace":"argocd",
                  "ownerReferences":[{"kind":"ApplicationSet","name":"observability"}],
                  "creationTimestamp":"2024-03-01T08:30:00Z"},
      "spec":{"source":{"repoURL":"https://prometheus-community.github.io/helm-charts",
                        "chart":"kube-prometheus-stack","targetRevision":"56.2.1"}},
      "status":{"sync":{"status":"Synced","revision":"56.2.1"},"health":{"status":"Healthy"}}
    }]}
    """)
    let apps = KubernetesGitOpsService.parseArgoCDApplications(items)
    assert(!apps.isEmpty)
    let app = apps[0]
    assert(app.sourceKind == .helmChart, "chart-sourced app reported as \(app.sourceKind.rawValue)")
    assert(app.chart == "kube-prometheus-stack")
    assert(app.targetRevision == "56.2.1")
    // A chart version is not a SHA and must survive intact.
    assert(app.syncedRevision == "56.2.1")
    assert(app.managedBy == "ApplicationSet/observability")
}

/// Manifests in Git that ArgoCD renders through Helm are a different thing from a
/// chart pulled from a chart repo, and must not be collapsed into it.
func testArgoCDHelmRenderedFromGitIsDistinctFromAChartSource() throws {
    let items = try jsonItems("""
    {"items":[{
      "metadata":{"name":"payments","namespace":"argocd"},
      "spec":{"source":{"repoURL":"https://git.example.com/org/payments.git","path":"deploy",
                        "targetRevision":"main","helm":{"valueFiles":["values-prod.yaml"]}}},
      "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}
    }]}
    """)
    let apps = KubernetesGitOpsService.parseArgoCDApplications(items)
    assert(!apps.isEmpty)
    let app = apps[0]
    assert(app.sourceKind == .helmFromGit, "got \(app.sourceKind.rawValue)")
    assert(app.chart == KubernetesGitOpsService.unknownValue, "no chart repo involved, must not invent one")
    assert(app.path == "deploy")
}

func testArgoCDOCIAndMultiSourceApplications() throws {
    let items = try jsonItems("""
    {"items":[
      {"metadata":{"name":"edge","namespace":"argocd"},
       "spec":{"source":{"repoURL":"oci://registry.example.com/charts","chart":"edge","targetRevision":"1.4.0"}},
       "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
      {"metadata":{"name":"bundle","namespace":"argocd"},
       "spec":{"sources":[
         {"repoURL":"https://git.example.com/a.git","path":"base","targetRevision":"main"},
         {"repoURL":"https://charts.example.com","chart":"sidecar","targetRevision":"2.0.0"}]},
       "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}
    ]}
    """)
    let apps = KubernetesGitOpsService.parseArgoCDApplications(items)
    assert(apps[0].sourceKind == .oci, "oci:// source reported as \(apps[0].sourceKind.rawValue)")
    assert(apps[1].additionalSourceCount == 1, "multi-source app must not look single-source")
    assert(apps[1].repoURL == "https://git.example.com/a.git")
}

/// An application the controller has not reported on yet must read as unknown, not
/// as healthy. This is the exact fabrication the old screen shipped.
func testGitOpsNeverInventsSyncOrHealth() throws {
    let items = try jsonItems("""
    {"items":[{"metadata":{"name":"fresh","namespace":"argocd"},
               "spec":{"source":{"repoURL":"https://git.example.com/x.git","targetRevision":"main"}},
               "status":{}}]}
    """)
    let apps = KubernetesGitOpsService.parseArgoCDApplications(items)
    assert(!apps.isEmpty)
    let app = apps[0]
    assert(app.syncStatus == KubernetesGitOpsService.unknownValue, "got \(app.syncStatus)")
    assert(app.healthStatus == KubernetesGitOpsService.unknownValue, "got \(app.healthStatus)")
    assert(app.syncedRevision == KubernetesGitOpsService.unknownValue)
}

func testFluxKustomizationAndHelmReleaseReportRealState() throws {
    let kustomizations = try jsonItems("""
    {"items":[{
      "metadata":{"name":"infra","namespace":"flux-system","creationTimestamp":"2024-02-01T00:00:00Z"},
      "spec":{"path":"./clusters/prod","sourceRef":{"kind":"GitRepository","name":"platform"}},
      "status":{"lastAppliedRevision":"main@sha1:aabbccdd11223344556677889900aabbccddeeff",
                "conditions":[{"type":"Ready","status":"True"}]}
    }]}
    """)
    let parsedKustomizations = KubernetesGitOpsService.parseFluxKustomizations(kustomizations)
    assert(!parsedKustomizations.isEmpty)
    let kustomization = parsedKustomizations[0]
    assert(kustomization.provider == "Flux CD" && kustomization.kind == "Kustomization")
    assert(kustomization.syncStatus == "Synced" && kustomization.healthStatus == "Healthy")
    assert(kustomization.repoURL == "platform")
    assert(kustomization.path == "./clusters/prod")
    assert(kustomization.syncedRevision == "main@aabbccd", "branch context must survive, got \(kustomization.syncedRevision)")

    let helmReleases = try jsonItems("""
    {"items":[
      {"metadata":{"name":"ingress-nginx","namespace":"ingress"},
       "spec":{"chart":{"spec":{"chart":"ingress-nginx","version":"4.9.1",
                                "sourceRef":{"kind":"HelmRepository","name":"ingress-nginx"}}}},
       "status":{"lastAppliedRevision":"4.9.1",
                 "conditions":[{"type":"Ready","status":"False","reason":"InstallFailed"}]}},
      {"metadata":{"name":"paused","namespace":"ops"},
       "spec":{"suspend":true,"chart":{"spec":{"chart":"ops-tools","version":"1.0.0"}}},
       "status":{"conditions":[{"type":"Ready","status":"True"}]}}
    ]}
    """)
    let releases = KubernetesGitOpsService.parseFluxHelmReleases(helmReleases)
    assert(releases[0].sourceKind == .helmChart)
    assert(releases[0].chart == "ingress-nginx" && releases[0].targetRevision == "4.9.1")
    assert(releases[0].syncStatus == "OutOfSync")
    assert(releases[0].healthStatus == "InstallFailed", "failure reason should surface, got \(releases[0].healthStatus)")
    assert(releases[1].syncStatus == "Suspended", "a suspended release must not read as Synced")
}

/// A cluster with ArgoCD but no Flux (or the reverse) must still show what it has.
/// kubectl fails the whole command for an unknown type, which is why each CRD is
/// read separately and a missing one is treated as "not installed".
func testMissingCRDIsNotInstalledRatherThanAnError() throws {
    assert(KubernetesGitOpsReader.indicatesMissingCRD(
        "error: the server doesn't have a resource type \"kustomizations\""))
    assert(KubernetesGitOpsReader.indicatesMissingCRD(
        "error: unable to recognize \"\": no matches for kind \"Application\" in version \"argoproj.io/v1alpha1\""))
    // RBAC denial is a real failure and must stay visible.
    assert(!KubernetesGitOpsReader.indicatesMissingCRD(
        "Error from server (Forbidden): applications.argoproj.io is forbidden"))
    assert(!KubernetesGitOpsReader.indicatesMissingCRD(
        "Unable to connect to the server: dial tcp: i/o timeout"))
}

/// `helm list -o json` is the authoritative source: chart and app version come from
/// Helm itself rather than being guessed from a secret name.
func testHelmListJSONParsesRealReleaseFields() throws {
    let releases = KubernetesHelmReader.parseHelmListJSON("""
    [{"name":"ingress-nginx","namespace":"ingress","revision":"7",
      "updated":"2024-05-04 11:22:33.123456 +0000 UTC","status":"deployed",
      "chart":"ingress-nginx-4.9.1","app_version":"1.9.6"},
     {"name":"redis","namespace":"cache","revision":"2",
      "updated":"2024-05-01 09:00:00.0 +0000 UTC","status":"failed",
      "chart":"redis-18.1.2","app_version":"7.2.4"}]
    """)
    assert(releases.count == 2)
    let ingress = releases.first { $0.name == "ingress-nginx" }!
    assert(ingress.chart == "ingress-nginx-4.9.1", "chart must come from helm, got \(ingress.chart)")
    assert(ingress.appVersion == "1.9.6")
    assert(ingress.revision == 7)
    assert(ingress.status == "deployed")
    assert(ingress.updated != KubernetesGitOpsService.unknownValue, "helm's Go timestamp should parse")

    let redis = releases.first { $0.name == "redis" }!
    assert(redis.status == "failed", "a failed release must not be reported as deployed")
}

/// Fallback path when the helm binary isn't installed. Real name, revision, status
/// and age come from the release Secret's labels; chart and app version live only
/// inside the Secret payload, which CTX does not read, so they stay unknown.
func testHelmReleaseSecretLabelsKeepOnlyTheCurrentRevision() throws {
    let releases = KubernetesHelmReader.parseReleaseSecretLabels("""
    ingress   ingress-nginx   5   superseded   2024-04-01T10:00:00Z
    ingress   ingress-nginx   7   deployed     2024-05-04T11:22:33Z
    ingress   ingress-nginx   6   superseded   2024-04-20T10:00:00Z
    cache     redis           2   failed       2024-05-01T09:00:00Z
    other     <none>          1   deployed     2024-05-01T09:00:00Z
    """)
    assert(releases.count == 2, "one row per release, got \(releases.count)")
    let ingress = releases.first { $0.name == "ingress-nginx" }!
    assert(ingress.revision == 7, "must keep the highest revision, got \(ingress.revision)")
    assert(ingress.status == "deployed")
    assert(ingress.chart == KubernetesGitOpsService.unknownValue, "chart lives in the secret payload and must not be guessed")
    assert(ingress.appVersion == KubernetesGitOpsService.unknownValue)
    let redis = releases.first { $0.name == "redis" }!
    assert(redis.status == "failed")
}

/// The Helm fallback reads labels and creation time only — never `.data`, which
/// would be a secret value.
func testHelmSecretFallbackNeverRequestsSecretValues() async throws {
    let runner = ScriptedKubectl()
    runner.defaultOutput = .success("")
    let reader = KubernetesHelmReader(kubectl: runner, resolveBinary: { _ in nil })
    _ = await reader.releases(context: testKubernetesContext(), namespace: .allNamespaces)
    let arguments = runner.commands.flatMap(\.arguments)
    assert(arguments.contains { $0.contains("custom-columns") }, "expected a custom-columns projection")
    assert(!arguments.contains { $0.contains(".data") }, "secret payload must never be requested")
    assert(!arguments.contains("--output=json"), "secret JSON must never be requested")
    assert(arguments.contains("owner=helm"))
}

/// Answers per resource type, so a cluster can be modelled as "ArgoCD installed,
/// Flux not" — the case that used to make the whole screen blank or fabricate rows.
final class CRDAwareKubectl: KubectlRunning, KubectlCommandBuilding, @unchecked Sendable {
    var responses: [String: KubectlResult] = [:]
    var missingResourceStderr = "error: the server doesn't have a resource type"
    var delayNanoseconds: UInt64 = 0
    private(set) var requestedResources: [String] = []
    private(set) var lastArguments: [String] = []
    private let queue = DispatchQueue(label: "ctx.tests.crd-kubectl")

    func inspectionCommand(context: String, arguments: [String]) throws -> KubectlCommand {
        KubectlCommand(executablePath: "/mock/kubectl", arguments: ["--context", context] + arguments)
    }

    func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult {
        guard let getIndex = command.arguments.firstIndex(of: "get"),
              command.arguments.indices.contains(getIndex + 1) else {
            return KubectlResult(exitCode: 1, stdout: "", stderr: "unexpected command")
        }
        let resource = command.arguments[getIndex + 1]
        queue.sync {
            requestedResources.append(resource)
            lastArguments = command.arguments
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let response = responses[resource] { return response }
        return KubectlResult(exitCode: 1, stdout: "", stderr: "\(missingResourceStderr) \"\(resource)\"")
    }
}

func testGitOpsReaderShowsArgoCDEvenWhenFluxIsNotInstalled() async throws {
    let kubectl = CRDAwareKubectl()
    kubectl.responses["applications.argoproj.io"] = KubectlResult(exitCode: 0, stdout: """
    {"items":[
      {"metadata":{"name":"checkout","namespace":"argocd"},
       "spec":{"source":{"repoURL":"https://git.example.com/a.git","path":"apps","targetRevision":"main"}},
       "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
      {"metadata":{"name":"grafana","namespace":"argocd"},
       "spec":{"source":{"repoURL":"https://grafana.github.io/helm-charts","chart":"grafana","targetRevision":"7.3.0"}},
       "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}
    ]}
    """, stderr: "")

    let reader = KubernetesGitOpsReader(kubectl: kubectl)
    let result = await reader.applications(context: testKubernetesContext(), namespace: .allNamespaces)

    assert(result.status == .reachable, "a missing Flux CRD must not fail the whole read")
    assert(result.installedControllers == ["ArgoCD"], "got \(result.installedControllers)")
    assert(result.items.count == 2, "got \(result.items.count) apps")
    // Both ArgoCD delivery styles must be represented, not flattened into one.
    assert(result.items.contains { $0.sourceKind == .git })
    assert(result.items.contains { $0.sourceKind == .helmChart && $0.chart == "grafana" })
    // All three controller resource types are probed independently.
    assert(kubectl.requestedResources.count == 3, "got \(kubectl.requestedResources)")
}

/// A cluster with neither controller is a normal state with its own empty message —
/// not an error, and not an excuse to show invented rows.
func testGitOpsReaderReportsNoControllersInstalled() async throws {
    let reader = KubernetesGitOpsReader(kubectl: CRDAwareKubectl())
    let result = await reader.applications(context: testKubernetesContext(), namespace: .allNamespaces)
    assert(result.status == .reachable)
    assert(result.installedControllers.isEmpty)
    assert(result.items.isEmpty)
}

/// RBAC denial or an unreachable cluster is a real failure and must surface as one,
/// rather than being swallowed as "no controller installed".
func testGitOpsReaderSurfacesRealFailures() async throws {
    let kubectl = CRDAwareKubectl()
    kubectl.missingResourceStderr = "Error from server (Forbidden): applications.argoproj.io is forbidden"
    let reader = KubernetesGitOpsReader(kubectl: kubectl)
    let result = await reader.applications(context: testKubernetesContext(), namespace: .allNamespaces)
    assert(result.status != .reachable, "forbidden must not read as a healthy empty cluster")
    assert(result.diagnostic != nil)
}

// MARK: - Pod spec is read from the object, never guessed from its name

let realPodJSON = """
{"metadata":{"name":"checkout-7d9f","namespace":"shop"},
 "spec":{
   "serviceAccountName":"checkout-sa","nodeName":"node-worker-a",
   "securityContext":{"runAsUser":1000,"runAsNonRoot":true},
   "initContainers":[{"name":"migrate","image":"registry.example.com/migrate:2.1"}],
   "containers":[{
     "name":"app","image":"registry.example.com/checkout:1.4.2",
     "env":[
       {"name":"APP_ENV","value":"production"},
       {"name":"DB_PASSWORD","valueFrom":{"secretKeyRef":{"name":"db-creds","key":"password"}}},
       {"name":"FEATURE_FLAGS","valueFrom":{"configMapKeyRef":{"name":"checkout-config","key":"flags"}}},
       {"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}],
     "envFrom":[{"secretRef":{"name":"shared-secrets"}}],
     "livenessProbe":{"httpGet":{"path":"/healthz","port":9090,"scheme":"HTTPS"},
                      "initialDelaySeconds":15,"periodSeconds":20},
     "readinessProbe":{"tcpSocket":{"port":"http"},"initialDelaySeconds":3,"periodSeconds":5},
     "securityContext":{"privileged":true,"readOnlyRootFilesystem":true,
                        "capabilities":{"add":["NET_ADMIN"]}},
     "resources":{"requests":{"cpu":"250m","memory":"512Mi"},"limits":{"memory":"1Gi"}}}]}}
"""

/// Secret-backed variables must expose their reference and never a value — CTX
/// does not read the Secret at all. The old inspector printed invented values like
/// "secret123" that looked entirely real.
func testPodEnvExposesReferencesButNeverSecretValues() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!

    let literal = app.env.first { $0.name == "APP_ENV" }!
    assert(literal.value == "production" && literal.source.isEmpty)
    assert(!literal.isSecret)

    let secret = app.env.first { $0.name == "DB_PASSWORD" }!
    assert(secret.isSecret)
    assert(secret.value.isEmpty, "a Secret-backed value must never be materialised")
    assert(secret.source == "Secret db-creds/password", "got \(secret.source)")

    let configMap = app.env.first { $0.name == "FEATURE_FLAGS" }!
    assert(configMap.source == "ConfigMap checkout-config/flags" && !configMap.isSecret)

    let field = app.env.first { $0.name == "POD_IP" }!
    assert(field.source == "field status.podIP")

    // envFrom pulls in every key at once; only the reference is knowable.
    let bulk = app.env.first { $0.source == "Secret shared-secrets" }!
    assert(bulk.isSecret && bulk.value.isEmpty)

    // Nothing anywhere carries a materialised secret value.
    assert(!app.env.contains { $0.isSecret && !$0.value.isEmpty })
}

func testPodProbesReportRealTargetsAndAbsence() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!

    let liveness = app.probes.first { $0.type == "Liveness" }!
    assert(liveness.isConfigured)
    assert(liveness.target == "HTTPS GET /healthz:9090", "got \(liveness.target)")
    assert(liveness.delaySeconds == 15 && liveness.periodSeconds == 20)

    // A named port must survive as its name, not be coerced to a number.
    let readiness = app.probes.first { $0.type == "Readiness" }!
    assert(readiness.target == "TCP :http", "got \(readiness.target)")

    // An unset probe is a real finding, not a value to invent.
    let startup = app.probes.first { $0.type == "Startup" }!
    assert(!startup.isConfigured)
}

/// Container-level security context wins; anything it leaves unset falls back to
/// the pod-level one, which is how the kubelet resolves it.
func testPodSecurityContextMergesContainerOverPodLevel() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!
    assert(app.security.runAsUser == "1000", "pod-level runAsUser should apply, got \(app.security.runAsUser)")
    assert(!app.security.isRoot)
    assert(app.security.isPrivileged, "container-level privileged must be honoured")
    assert(app.security.isReadOnlyRootFS)
    assert(app.security.addedCapabilities == ["NET_ADMIN"])
}

/// An unset security context is unknown, not "safe" — and UID 0 is root.
func testPodSecurityContextDoesNotAssumeSafetyWhenUnset() throws {
    let bare = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: """
    {"spec":{"containers":[{"name":"c","image":"i"}]}}
    """)!.containers[0]
    assert(bare.security.runAsUser == KubernetesGitOpsService.unknownValue)
    assert(!bare.security.isRoot && !bare.security.isPrivileged)

    let rootPod = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: """
    {"spec":{"containers":[{"name":"c","image":"i","securityContext":{"runAsUser":0}}]}}
    """)!.containers[0]
    assert(rootPod.security.isRoot, "UID 0 must be reported as root")
}

/// An absent limit stays absent — that is the finding (the container can consume
/// the whole node), not a blank to fill with a plausible number.
func testPodResourcesKeepUnsetLimitsUnset() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!
    assert(app.resources.cpuRequest == "250m")
    assert(app.resources.memoryRequest == "512Mi")
    assert(app.resources.memoryLimit == "1Gi")
    assert(app.resources.cpuLimit == nil, "an unset CPU limit must not be invented")
}

func testPodSpecIncludesInitContainersAndIdentity() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    assert(spec.containers.count == 2)
    assert(spec.containers[0].isInitContainer && spec.containers[0].name == "migrate")
    assert(!spec.containers[1].isInitContainer)
    assert(spec.serviceAccount == "checkout-sa")
    assert(spec.nodeName == "node-worker-a")
}

/// Not-ready backends are exactly what someone debugging "the service is up but
/// nothing answers" needs to see, so they are kept and flagged rather than hidden.
func testServiceEndpointsReportReadyAndNotReadyBackends() throws {
    let targets = KubernetesWorkloadSpecParser.endpoints(fromEndpointsJSON: """
    {"metadata":{"name":"checkout","namespace":"shop"},
     "subsets":[{"ports":[{"port":8080,"name":"http"}],
                 "addresses":[{"ip":"10.1.2.3","targetRef":{"name":"checkout-a","namespace":"shop"}}],
                 "notReadyAddresses":[{"ip":"10.1.2.4","targetRef":{"name":"checkout-b","namespace":"shop"}}]}]}
    """)
    assert(targets.count == 2)
    let ready = targets.first { $0.name == "checkout-a" }!
    assert(ready.isHealthy && ready.address == "10.1.2.3" && ready.targetPort == "8080/http")
    let notReady = targets.first { $0.name == "checkout-b" }!
    assert(!notReady.isHealthy, "a not-ready backend must not be reported as healthy")

    // A Service with no backends at all yields nothing — not two invented pods.
    assert(KubernetesWorkloadSpecParser.endpoints(fromEndpointsJSON: #"{"metadata":{},"subsets":[]}"#).isEmpty)
}

func testNodeCapacityComesFromTheNodeObject() throws {
    let node: [String: Any] = [
        "status": ["capacity": ["cpu": "8", "memory": "32Gi", "pods": "110"],
                   "allocatable": ["cpu": "7910m", "memory": "30Gi", "pods": "110"]]
    ]
    let capacity = KubernetesWorkloadSpecParser.nodeCapacity(fromNodeObject: node)!
    // Allocatable is what can actually be scheduled, so it wins over raw capacity.
    assert(capacity.cpu == "7910m", "got \(capacity.cpu)")
    assert(capacity.memory == "30Gi")
    assert(capacity.pods == "110")
}

try testPodEnvExposesReferencesButNeverSecretValues()
try testPodProbesReportRealTargetsAndAbsence()
try testPodSecurityContextMergesContainerOverPodLevel()
try testPodSecurityContextDoesNotAssumeSafetyWhenUnset()
try testPodResourcesKeepUnsetLimitsUnset()
try testPodSpecIncludesInitContainersAndIdentity()
try testServiceEndpointsReportReadyAndNotReadyBackends()
try testNodeCapacityComesFromTheNodeObject()

// MARK: - Depth pass on the GitOps and Helm reads

/// The bug that made the whole feature useless in practice: ArgoCD `Application`
/// objects live in the *controller's* namespace (`argocd`) while the workloads they
/// deliver land elsewhere. Scoping the read to the workspace's selected namespace
/// returned nothing for every namespace but the controller's own.
func testGitOpsIsReadClusterWideRegardlessOfSelectedNamespace() async throws {
    for scope in [KubernetesNamespaceSelection.defaultNamespace,
                  .namespace("shop"),
                  .allNamespaces] {
        let kubectl = CRDAwareKubectl()
        kubectl.responses["applications.argoproj.io"] = KubectlResult(exitCode: 0, stdout: """
        {"items":[{"metadata":{"name":"checkout","namespace":"argocd"},
                   "spec":{"source":{"repoURL":"https://git.example.com/a.git","targetRevision":"main"}},
                   "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}
        """, stderr: "")
        let reader = KubernetesGitOpsReader(kubectl: kubectl)
        let result = await reader.applications(context: testKubernetesContext(), namespace: scope)

        assert(result.items.count == 1, "app hidden when scope was \(scope.storageValue)")
        let arguments = kubectl.lastArguments
        assert(arguments.contains("--all-namespaces"),
               "GitOps must always read cluster-wide, got \(arguments)")
        assert(!arguments.contains("--namespace"),
               "GitOps must never be namespace-scoped, got \(arguments)")
    }
}

/// A partial failure — ArgoCD readable, Flux forbidden — must keep the readable
/// apps on screen *and* admit the list is incomplete, rather than presenting a
/// truncated list as if it were the whole picture.
func testGitOpsPartialFailureKeepsAppsAndReportsIncompleteness() async throws {
    let kubectl = CRDAwareKubectl()
    kubectl.responses["applications.argoproj.io"] = KubectlResult(exitCode: 0, stdout: """
    {"items":[{"metadata":{"name":"checkout","namespace":"argocd"},
               "spec":{"source":{"repoURL":"https://git.example.com/a.git","targetRevision":"main"}},
               "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}
    """, stderr: "")
    kubectl.responses["kustomizations.kustomize.toolkit.fluxcd.io"] =
        KubectlResult(exitCode: 1, stdout: "", stderr: "Error from server (Forbidden): kustomizations is forbidden")

    let reader = KubernetesGitOpsReader(kubectl: kubectl)
    let result = await reader.applications(context: testKubernetesContext(), namespace: .allNamespaces)

    assert(result.items.count == 1, "readable apps must survive a sibling failure")
    assert(result.installedControllers == ["ArgoCD"])
    assert(result.status == .reachable)
    assert(result.diagnostic != nil, "an unreadable controller must not vanish silently")
}

/// Three CRDs read serially cost three round trips before anything rendered.
func testGitOpsReadsControllersConcurrently() async throws {
    let kubectl = CRDAwareKubectl()
    kubectl.delayNanoseconds = 250_000_000
    let started = Date()
    _ = await KubernetesGitOpsReader(kubectl: kubectl)
        .applications(context: testKubernetesContext(), namespace: .allNamespaces)
    let elapsed = Date().timeIntervalSince(started)
    assert(kubectl.requestedResources.count == 3)
    assert(elapsed < 0.6, "three 250ms reads should overlap, took \(elapsed)s")
}

/// Flux reports "<branch>@sha1:<digest>". Truncating to the bare hash threw away
/// which branch was deployed — half of what the field is for.
func testShortRevisionKeepsBranchAndLeavesVersionsIntact() throws {
    assert(KubernetesGitOpsService.shortRevision("main@sha1:aabbccdd11223344556677889900aabbccddeeff") == "main@aabbccd")
    assert(KubernetesGitOpsService.shortRevision("9f3c1ab7de5544aa10bb2231cc99887766554433") == "9f3c1ab")
    assert(KubernetesGitOpsService.shortRevision("sha256:aabbccdd11223344556677889900aabbccddeeff") == "aabbccd")
    // Not hashes — these must survive untouched.
    assert(KubernetesGitOpsService.shortRevision("56.2.1") == "56.2.1")
    assert(KubernetesGitOpsService.shortRevision("v1.4.2") == "v1.4.2")
    assert(KubernetesGitOpsService.shortRevision("release-2.4") == "release-2.4")
    assert(KubernetesGitOpsService.shortRevision(nil) == KubernetesGitOpsService.unknownValue)
}

/// `helm list` without `--all` filters out exactly the releases worth seeing: a
/// deploy stuck in pending-upgrade is invisible by default.
func testHelmListAsksForEveryReleaseState() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("[]")
    let reader = KubernetesHelmReader(kubectl: kubectl, resolveBinary: { _ in "/mock/helm" })
    _ = await reader.releases(context: testKubernetesContext(), namespace: .allNamespaces)
    let arguments = kubectl.commands.flatMap(\.arguments)
    assert(arguments.contains("--all"), "pending releases would be hidden, got \(arguments)")
    assert(arguments.contains("--all-namespaces"))
    assert(arguments.contains("--kube-context"), "helm must be pinned to the workspace context")
}

/// Two `envFrom` entries in one container both carry the placeholder name
/// "(all keys)". Identical ids break `ForEach` identity in SwiftUI.
func testEnvVarIdentityStaysUniqueAcrossBulkReferences() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: """
    {"spec":{"containers":[{"name":"app","image":"i","envFrom":[
      {"secretRef":{"name":"shared-secrets"}},
      {"secretRef":{"name":"extra-secrets"}},
      {"configMapRef":{"name":"app-config"}}]}]}}
    """)!
    let env = spec.containers[0].env
    assert(env.count == 3)
    assert(Set(env.map(\.id)).count == 3, "duplicate identifiers: \(env.map(\.id))")
    assert(env.filter(\.isSecret).count == 2)
    assert(!env.contains { !$0.value.isEmpty }, "bulk references have no readable value")
}

try await testGitOpsIsReadClusterWideRegardlessOfSelectedNamespace()
try await testGitOpsPartialFailureKeepsAppsAndReportsIncompleteness()
try await testGitOpsReadsControllersConcurrently()
try testShortRevisionKeepsBranchAndLeavesVersionsIntact()
try await testHelmListAsksForEveryReleaseState()
try testEnvVarIdentityStaysUniqueAcrossBulkReferences()

try await testGitOpsReaderShowsArgoCDEvenWhenFluxIsNotInstalled()
try await testGitOpsReaderReportsNoControllersInstalled()
try await testGitOpsReaderSurfacesRealFailures()
try testArgoCDGitBackedApplicationReportsRealFields()
try testArgoCDHelmChartApplicationIsIdentifiedAsAChart()
try testArgoCDHelmRenderedFromGitIsDistinctFromAChartSource()
try testArgoCDOCIAndMultiSourceApplications()
try testGitOpsNeverInventsSyncOrHealth()
try testFluxKustomizationAndHelmReleaseReportRealState()
try testMissingCRDIsNotInstalledRatherThanAnError()
try testHelmListJSONParsesRealReleaseFields()
try testHelmReleaseSecretLabelsKeepOnlyTheCurrentRevision()
try await testHelmSecretFallbackNeverRequestsSecretValues()

try await testCloudCommandRunnerTerminatesAHangingProcess()
try await testCloudCommandRunnerCancellationTerminatesTheSubprocess()
try await testProfileFileWatcherSurvivesAtomicReplacement()
try testShellCommandSafetyRejectsInjection()

// MARK: - Phase 2: derived state stays cached and correct

/// The grouping is now stored rather than computed, so the risk shifts from "too
/// slow" to "stale". Every mutation path that feeds it must rebuild it.
@MainActor
func testGroupedProfilesStayInSyncWithEveryMutation() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-group-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("config")
    try """
    [profile shop-prod]
    sso_account_id = 123456789012
    sso_role_name = Admin

    [profile shop-dev]
    sso_account_id = 123456789012
    sso_role_name = Admin
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-group-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("creds")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    // Scoped to AWS: discovery also picks up whatever GCP/Azure configurations
    // exist on the machine running the tests, and every provider has its own
    // folder named "Production".
    func grouped(_ folderName: String) -> [String] {
        store.groupedProfiles
            .first { $0.folder.provider == .aws && $0.folder.name == folderName }?
            .profiles.map(\.name).sorted() ?? []
    }

    // Built at init: environment inference splits the two profiles by name.
    assert(!store.allFolders.isEmpty, "folders must be built during init, where didSet does not fire")
    assert(grouped("Production") == ["shop-prod"], "got \(grouped("Production"))")
    assert(grouped("Development") == ["shop-dev"], "got \(grouped("Development"))")

    // Moving a profile must be reflected without any other trigger.
    let prod = store.profiles.first { $0.name == "shop-prod" }!
    let devFolder = store.allFolders.first { $0.provider == .aws && $0.name == "Development" }!
    store.move(prod, to: devFolder)
    assert(grouped("Development") == ["shop-dev", "shop-prod"], "override did not rebuild grouping: \(grouped("Development"))")
    assert(grouped("Production").isEmpty)

    // Creating a folder must appear, and deleting it must both disappear and
    // release the profiles it held.
    try store.addFolder(name: "Payments", provider: .aws, icon: .cloud)
    let payments = store.allFolders.first { $0.name == "Payments" }!
    assert(store.folders(for: .aws).contains { $0.id == payments.id }, "folders(for:) must see a new folder")
    store.move(prod, to: payments)
    assert(grouped("Payments") == ["shop-prod"])

    store.deleteFolder(payments)
    assert(!store.allFolders.contains { $0.id == payments.id })
    assert(grouped("Production") == ["shop-prod"], "profile must fall back to its inferred folder: \(grouped("Production"))")

    // Hiding a built-in folder removes it from both views.
    let production = store.allFolders.first { $0.provider == .aws && $0.name == "Production" }!
    store.deleteFolder(production)
    assert(!store.allFolders.contains { $0.id == production.id })
    assert(!store.groupedProfiles.contains { $0.folder.id == production.id })
    _ = production

    store.restoreAllFolders()
    assert(store.allFolders.contains { $0.id == production.id }, "restore must rebuild the folder list")
    assert(grouped("Production") == ["shop-prod"])

    // A rename must reach both the folder list and the grouping.
    try store.updateFolder(store.allFolders.first { $0.provider == .aws && $0.name == "Production" }!, name: "Live", icon: .server)
    assert(store.allFolders.contains { $0.name == "Live" })
    assert(grouped("Live") == ["shop-prod"], "rename did not rebuild grouping")
}

/// A profile whose override points at another provider's folder used to be matched
/// by no group at all and vanished from the sidebar entirely.
@MainActor
func testCrossProviderOverrideFallsBackInsteadOfHidingTheProfile() throws {
    let store = ProfileStore(startsBackgroundServices: false)
    let profile = CloudProfile(provider: .aws, name: "shop-prod")
    let gcpFolder = CloudFolder.builtIn(provider: .gcp, environment: .production)
    store.move(profile, to: gcpFolder)
    let resolved = store.folder(for: profile)
    assert(resolved.provider == .aws, "a mismatched override must fall back, got \(resolved.provider)")
}

/// One parse of the credentials file for all profiles, not one parse per profile.
func testCredentialExpiriesParseEveryProfileInOnePass() throws {
    let text = """
    [alpha]
    aws_access_key_id = A
    aws_session_expiration = 2030-01-01T10:00:00Z

    [beta]
    aws_session_expiration = 2030-01-02T11:30:00+00:00

    [gamma]
    aws_access_key_id = C
    """
    let expiries = AWSSessionExpirationService.credentialExpiries(credentialsText: text)
    assert(expiries.count == 2, "got \(expiries.keys.sorted())")
    assert(expiries["alpha"] != nil && expiries["beta"] != nil)
    assert(expiries["gamma"] == nil, "a profile with no expiry must not appear")

    // Same answer as the single-profile lookup it replaced.
    for name in ["alpha", "beta", "gamma"] {
        assert(expiries[name] == AWSSessionExpirationService.credentialsExpiry(for: name, credentialsText: text),
               "bulk and single-profile parsing disagree for \(name)")
    }
}

try testGroupedProfilesStayInSyncWithEveryMutation()
try testCrossProviderOverrideFallsBackInsteadOfHidingTheProfile()
try testCredentialExpiriesParseEveryProfileInOnePass()

/// The search haystack is derived state that must survive the disk cache: a row
/// decoded from SQLite has to filter exactly like a freshly parsed one.
func testRowFilteringSurvivesEncodingAndMatchesTheOldSemantics() throws {
    let row = KubernetesResourceRow(id: "team-a/api-7d9f", cells: [
        "Namespace": "team-a", "Name": "api-7d9f", "Status": "CrashLoopBackOff",
        "Node": "node-worker-3", "Age": "4d"
    ])

    // Values, keys, the id, and case-insensitivity.
    for needle in ["api", "API", "crashloop", "team-a", "node-worker-3", "Status", "team-a/api"] {
        assert(row.matchesFilter(needle), "should match '\(needle)'")
    }
    for needle in ["nomatch", "node-worker-30", "zzz"] {
        assert(!row.matchesFilter(needle), "should not match '\(needle)'")
    }
    // Empty and whitespace-only filters match everything.
    assert(row.matchesFilter("") && row.matchesFilter("   "))
    // Padding around a real term is trimmed.
    assert(row.matchesFilter("  api  "))

    let decoded = try JSONDecoder().decode(KubernetesResourceRow.self, from: JSONEncoder().encode(row))
    assert(decoded == row)
    for needle in ["api", "CRASHLOOP", "node-worker-3", "Status"] {
        assert(decoded.matchesFilter(needle), "decoded row lost its search index for '\(needle)'")
    }
    assert(!decoded.matchesFilter("zzz"))

    // Batch and single-row entry points must agree.
    let rows = [row, KubernetesResourceRow(id: "team-b/web", cells: ["Name": "web"])]
    assert(KubernetesResourceRow.filtered(rows, matching: "api").map(\.id) == ["team-a/api-7d9f"])
    assert(KubernetesResourceRow.filtered(rows, matching: "").count == 2)
}

/// A rediscovery that finds exactly what was already there must not republish —
/// every watcher event would otherwise re-render the whole sidebar for no change.
@MainActor
func testUnchangedRediscoveryDoesNotRepublishProfiles() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-idem-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let configURL = dir.appendingPathComponent("config")
    try "[profile shop-prod]\nsso_account_id = 123456789012\n".write(to: configURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-idem-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("creds")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    // Let the first pass settle: rediscovery *plus* the verification behind it,
    // whose status transitions are real changes and must publish.
    store.refresh()
    try await Task.sleep(nanoseconds: 900_000_000)

    var publishCount = 0
    let cancellable = store.$profiles.dropFirst().sink { _ in publishCount += 1 }
    defer { cancellable.cancel() }

    // Second pass: nothing on disk changed and verification returns what it
    // returned last time, so the whole cycle must be a no-op.
    store.refresh()
    try await Task.sleep(nanoseconds: 900_000_000)
    assert(publishCount == 0, "an unchanged rediscovery republished \(publishCount) times")

    // A real change still comes through.
    try "[profile shop-prod]\nsso_account_id = 123456789012\n\n[profile shop-dev]\nsso_account_id = 210987654321\n"
        .write(to: configURL, atomically: true, encoding: .utf8)
    store.refresh()
    try await Task.sleep(nanoseconds: 900_000_000)
    assert(publishCount >= 1, "a real change must republish")
    // Scoped to this test's own config file: GCP and Azure discovery, and the
    // default kubeconfig, are not injectable, so the store also sees whatever the
    // machine running the tests happens to have.
    let discovered = store.profiles.filter { $0.name.hasPrefix("shop-") }.map(\.name).sorted()
    assert(discovered == ["shop-dev", "shop-prod"], "got \(discovered)")
}

try testRowFilteringSurvivesEncodingAndMatchesTheOldSemantics()
try await testUnchangedRediscoveryDoesNotRepublishProfiles()

// MARK: - Telemetry is measured, not assumed

let nodeCapacityJSON = """
{"items":[
 {"metadata":{"name":"node-big"},"status":{"allocatable":{"cpu":"96","memory":"384Gi","pods":"250"}}},
 {"metadata":{"name":"node-small"},"status":{"allocatable":{"cpu":"2","memory":"8Gi","pods":"30"}}}
]}
"""

/// Cluster utilisation is total usage over total allocatable, not the mean of the
/// per-node percentages. Averaging weights a two-core node the same as a
/// ninety-six-core one: the cluster below is genuinely at ~11.7% CPU, but a plain
/// mean of 10% and 90% reports 50%.
func testClusterUtilizationIsWeightedByAllocatable() throws {
    let capacity = KubernetesMetricsReader.parseNodeCapacity(nodeCapacityJSON)
    assert(capacity.count == 2)
    assert(capacity["node-big"]?.cpuCores == 96)
    assert(capacity["node-small"]?.podSlots == 30)

    // node-big: 9.6 of 96 cores (10%). node-small: 1.8 of 2 cores (90%).
    let nodes = KubernetesMetricsReader.parseTopNodes("""
    node-big     9600m   10%   38Gi   10%
    node-small   1800m   90%   7Gi    90%
    """, capacity: capacity)
    assert(nodes.count == 2)

    let cpu = KubernetesMetricsReader.aggregate(nodes, used: \.cpuUsedCores, allocatable: \.cpuAllocatableCores)!
    assert(abs(cpu - 11.63) < 0.1, "weighted CPU should be ~11.6%, got \(cpu)")
    assert(abs(cpu - 50) > 30, "a plain mean would have reported 50%")
}

/// The average hides the node that is actually about to evict pods.
func testBusiestNodeIsReportedAlongsideTheAverage() throws {
    let capacity = KubernetesMetricsReader.parseNodeCapacity(nodeCapacityJSON)
    let nodes = KubernetesMetricsReader.parseTopNodes("""
    node-big     9600m   10%   38Gi   10%
    node-small   1800m   90%   7Gi    90%
    """, capacity: capacity)
    let busiest = nodes.filter { $0.cpuPercent != nil }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }!
    assert(busiest.name == "node-small", "got \(busiest.name)")
    assert(abs((busiest.cpuPercent ?? 0) - 90) < 0.1)
}

/// A node whose allocatable is unknown is left out of both sides of the ratio
/// rather than counted as zero capacity, which would peg the cluster at 100%.
func testNodesWithUnknownCapacityAreExcludedNotZeroed() throws {
    let nodes = KubernetesMetricsReader.parseTopNodes("""
    known     1000m   50%   1Gi   50%
    unknown   9000m   90%   9Gi   90%
    """, capacity: ["known": KubernetesMetricsReader.NodeCapacity(cpuCores: 2, memoryBytes: nil, podSlots: nil)])
    let cpu = KubernetesMetricsReader.aggregate(nodes, used: \.cpuUsedCores, allocatable: \.cpuAllocatableCores)!
    assert(abs(cpu - 50) < 0.1, "only the node with known capacity should count, got \(cpu)")
    assert(KubernetesMetricsReader.aggregate(nodes, used: \.memoryUsedBytes, allocatable: \.memoryAllocatableBytes) == nil)
}

/// A pod counts as at-risk only against a limit it actually declares.
func testPodsNearMemoryLimitUsesDeclaredLimitsOnly() throws {
    let oneGiB = 1024.0 * 1024 * 1024
    let allNamespaces = """
    shop   checkout-a   120m   950Mi
    shop   checkout-b   80m    100Mi
    shop   nolimit-c    10m    4000Mi
    """
    let limits = ["shop/checkout-a": oneGiB, "shop/checkout-b": oneGiB]
    assert(KubernetesMetricsReader.podsNearMemoryLimit(topPodsOutput: allNamespaces, memoryLimitsByPodID: limits) == ["shop/checkout-a"])
    // No declared limit means no threshold to cross, however much is used.
    assert(KubernetesMetricsReader.podsNearMemoryLimit(topPodsOutput: allNamespaces, memoryLimitsByPodID: [:]).isEmpty)

    // Namespace-scoped output drops the NAMESPACE column; the same limits must match.
    let scoped = """
    checkout-a   120m   950Mi
    checkout-b   80m    100Mi
    """
    // Namespace-scoped output must still yield the namespace-qualified id, or the
    // at-risk list cannot be matched against the pod rows to filter them.
    assert(KubernetesMetricsReader.podsNearMemoryLimit(topPodsOutput: scoped, memoryLimitsByPodID: limits) == ["shop/checkout-a"],
           "namespace-scoped top output must resolve to the canonical namespace/name id")
}

func testQuantityParsingCoversCPUAndMemorySuffixes() throws {
    assert(KubernetesMetricsReader.cores("2") == 2)
    assert(KubernetesMetricsReader.cores("1500m") == 1.5)
    assert(abs((KubernetesMetricsReader.cores("2500000n") ?? 0) - 0.0025) < 1e-9)
    assert(KubernetesMetricsReader.bytes("1Ki") == 1024)
    assert(KubernetesMetricsReader.bytes("2Gi") == 2 * 1024 * 1024 * 1024)
    assert(KubernetesMetricsReader.bytes("1M") == 1_000_000)
    assert(KubernetesMetricsReader.bytes("nonsense") == nil)
}

func testPodDensityRequiresBothInputs() throws {
    assert(KubernetesMetricsReader.density(podCount: 55, allocatablePodSlots: 110) == 50)
    assert(KubernetesMetricsReader.density(podCount: 55, allocatablePodSlots: nil) == nil)
    assert(KubernetesMetricsReader.density(podCount: nil, allocatablePodSlots: 110) == nil)
    assert(KubernetesMetricsReader.density(podCount: 10, allocatablePodSlots: 0) == nil)
}

/// Telling someone to install metrics-server when the real problem is RBAC — or a
/// timeout — sends them to fix the wrong thing.
func testMetricsFailuresAreDistinguished() throws {
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "error: Metrics API not available")) == .notInstalled)
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "the server could not find the requested resource (get services http:heapster:)")) == .notInstalled)
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "Error from server (Forbidden): nodes.metrics.k8s.io is forbidden")) == .notInstalled
        || KubernetesMetricsReader.availability(from: KubectlResult(
            exitCode: 1, stdout: "", stderr: "Error from server (Forbidden): nodes is forbidden")) == .forbidden)
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "timed out", timedOut: true)) == .timedOut)
    // Every branch must produce something the UI can show.
    assert(MetricsAvailability.available.explanation == nil)
    for state: MetricsAvailability in [.notInstalled, .forbidden, .timedOut, .failed("boom")] {
        assert(state.explanation?.isEmpty == false)
    }
}

/// Without the metrics API, the numbers that do not need it still come through.
func testTelemetryWithoutMetricsAPIStillReportsWhatItCan() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .failure(stderr: "error: Metrics API not available")
    kubectl.outputs["get nodes --output=json --request-timeout=15s"] = .success(nodeCapacityJSON)

    let result = await KubernetesMetricsReader(kubectl: kubectl).telemetry(
        context: testKubernetesContext(),
        namespace: .allNamespaces,
        podCount: 140,
        podsByNode: [:],
        requests: ClusterResourceRequests(cpuCores: 49, memoryBytes: 196 * 1_073_741_824),
        memoryLimitsByPodID: [:]
    )
    assert(!result.hasMetrics)
    assert(result.availability == MetricsAvailability.notInstalled, "got \(result.availability)")
    assert(result.totalPods == 140)
    // 140 pods over 280 allocatable slots — derived from the node list, not metrics.
    assert(abs((result.podDensityPercent ?? 0) - 50) < 0.1, "got \(String(describing: result.podDensityPercent))")
    // Commitment comes from the pod requests and the node list, so it survives a
    // missing metrics API too: 49 of 98 cores, 196 of 392 GiB.
    assert(abs((result.requestedCPUPercent ?? 0) - 50) < 0.1, "got \(String(describing: result.requestedCPUPercent))")
    assert(abs((result.requestedMemoryPercent ?? 0) - 50) < 0.1, "got \(String(describing: result.requestedMemoryPercent))")
    assert(result.allocatableCPUCores == 98)
}

/// Utilisation and commitment are different questions. A cluster can sit at 2% CPU
/// and still refuse to schedule anything because its requests are nearly the whole
/// allocatable — reporting only utilisation hides exactly that.
func testCommitmentIsReportedSeparatelyFromUtilization() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .failure(stderr: "no metrics")
    kubectl.outputs["get nodes --output=json --request-timeout=15s"] = .success(nodeCapacityJSON)
    kubectl.outputs["top nodes --no-headers --request-timeout=15s"] = .success("""
    node-big     1960m   2%   8Gi    2%
    node-small   40m     2%   160Mi  2%
    """)

    let result = await KubernetesMetricsReader(kubectl: kubectl).telemetry(
        context: testKubernetesContext(),
        namespace: .allNamespaces,
        podCount: 200,
        podsByNode: ["node-big": 100, "node-small": 10],
        requests: ClusterResourceRequests(cpuCores: 93, memoryBytes: 0),
        memoryLimitsByPodID: [:]
    )
    let used = result.cpuUtilizedPercent ?? 0
    let committed = result.requestedCPUPercent ?? 0
    assert(used < 5, "cluster is nearly idle, got \(used)%")
    assert(committed > 90, "but almost fully committed, got \(committed)%")

    // Per-node utilisation is carried through for the Nodes table.
    assert(result.utilizationByNode.count == 2)
    assert(result.utilizationByNode["node-small"]?.cpuUsedCores == 0.04)

    // Peak density names no node — it is a cluster statistic, not a hostname.
    assert(result.peakNodePodPercent != nil)
}

try testClusterUtilizationIsWeightedByAllocatable()
try testBusiestNodeIsReportedAlongsideTheAverage()
try testNodesWithUnknownCapacityAreExcludedNotZeroed()
try testPodsNearMemoryLimitUsesDeclaredLimitsOnly()
try testQuantityParsingCoversCPUAndMemorySuffixes()
try testPodDensityRequiresBothInputs()
try testMetricsFailuresAreDistinguished()
try await testTelemetryWithoutMetricsAPIStillReportsWhatItCan()
try await testCommitmentIsReportedSeparatelyFromUtilization()

// MARK: - Pod hygiene score measures what the panel claims

func pod(_ name: String, cells extra: [String: String], warning: Bool = false) -> KubernetesResourceRow {
    var cells = ["Namespace": "shop", "Name": name, "Status": "Running", "Restarts": "0"]
    cells.merge(extra) { _, new in new }
    return KubernetesResourceRow(id: "shop/\(name)", cells: cells, warning: warning)
}

/// A fully-declared, healthy pod is the only thing that scores 100.
func testHygieneScoreRewardsFullyDeclaredHealthyPods() throws {
    let healthy = pod("api", cells: [
        "CPU Request Cores": "0.25", "Memory Request Bytes": "536870912", "Memory Limit": "1073741824"
    ])
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: healthy) == 100)

    // Each omission costs, and they accumulate.
    let noRequests = pod("api", cells: ["Memory Limit": "1073741824"])
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: noRequests) == 70, "got \(KubernetesRemediationAdvisor.workloadHygieneScore(pod: noRequests))")

    let nothingDeclared = pod("api", cells: [:])
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: nothingDeclared) == 60)

    let crashing = pod("api", cells: [
        "Status": "CrashLoopBackOff", "Restarts": "12",
        "CPU Request Cores": "0.25", "Memory Request Bytes": "1", "Memory Limit": "1"
    ], warning: true)
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: crashing) == 40)
}

/// The display cells now render an em dash for an undeclared request. The score used
/// to test for the ASCII "-", so after that change unset requests silently stopped
/// costing anything and every cluster's score drifted upward.
func testHygieneScoreReadsRawRequestsNotDisplayCells() throws {
    let displayOnly = pod("api", cells: [
        "CPU": KubernetesGitOpsService.unknownValue,
        "Memory": KubernetesGitOpsService.unknownValue
    ])
    // No raw request cells → the omission is still counted.
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: displayOnly) == 60,
           "got \(KubernetesRemediationAdvisor.workloadHygieneScore(pod: displayOnly))")
}

/// Workload rows carry no CPU or memory cells — the workloads list never asks for
/// them — so including them penalised every workload for data that was never
/// fetched, dragging the cluster score down by construction.
func testHygieneScoreIsPodsOnly() throws {
    let pods = [
        pod("a", cells: ["CPU Request Cores": "0.1", "Memory Request Bytes": "1", "Memory Limit": "1"]),
        pod("b", cells: ["CPU Request Cores": "0.1", "Memory Request Bytes": "1", "Memory Limit": "1"])
    ]
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pods: pods) == 100)

    // A workload-shaped row (no request cells at all) would score 60; it must not be
    // able to reach the cluster figure.
    let workloadShaped = KubernetesResourceRow(
        id: "shop/web", cells: ["Namespace": "shop", "Kind": "Deployment", "Name": "web", "Ready": "3/3"]
    )
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: workloadShaped) < 100)

    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pods: []) == 100, "no pods is not a failing cluster")
}

func testTopologyFailureEvaluatorPodFailures() {
    let crashingPod = TopologyFailureEvaluator.evaluatePod(cells: ["Status": "CrashLoopBackOff (Exit Code 137)", "Restarts": "14", "Ready": "0/1"])
    assert(crashingPod.isFailed)
    if case .failed(let reason, _, let exitCode, let restarts) = crashingPod {
        assert(reason.contains("CrashLoopBackOff"))
        assert(restarts == 14)
        assert(exitCode == 137)
    }

    let healthyPod = TopologyFailureEvaluator.evaluatePod(cells: ["Status": "Running", "Restarts": "0", "Ready": "1/1"])
    assert(healthyPod.isHealthy)

    for terminalStatus in ["Succeeded", "Completed"] {
        let terminal = TopologyFailureEvaluator.evaluatePod(cells: [
            "Status": terminalStatus, "Restarts": "0", "Ready": "0/1"
        ])
        assert(terminal.isIdle, "\(terminalStatus) must be idle before Ready evaluation")
    }
}

func testTopologyFailureEvaluatorServiceFailures() {
    let serviceNoPods = TopologyFailureEvaluator.evaluateService(cells: ["Selector": "app=missing"], matchedPodsCount: 0, workloadHealth: .healthy)
    assert(serviceNoPods.isFailed)
    if case .failed(let reason, _, _, _) = serviceNoPods {
        assert(reason == "No Target Endpoints")
    }
}

// MARK: - Cluster map graph

/// A cluster shaped like the ones the old map got wrong: two Deployments in one
/// namespace sharing an `app=shop` label (canary + stable), one Service in front
/// of both, a second Service selecting only the canary, one Ingress naming one
/// backend, one PVC mounted by exactly one pod, and an HPA on the stable
/// Deployment.
private func sampleMapRows() -> (
    services: [KubernetesResourceRow],
    workloads: [KubernetesResourceRow],
    pods: [KubernetesResourceRow],
    ingress: [KubernetesResourceRow],
    pvcs: [KubernetesResourceRow],
    hpas: [KubernetesResourceRow]
) {
    let services = [
        KubernetesResourceRow(id: "shop/shop-web", cells: [
            "Namespace": "shop", "Name": "shop-web", "Type": "ClusterIP",
            "Ports": "80/TCP", "Selector": "app=shop"
        ]),
        KubernetesResourceRow(id: "shop/shop-canary", cells: [
            "Namespace": "shop", "Name": "shop-canary", "Type": "ClusterIP",
            "Ports": "80/TCP", "Selector": "app=shop,track=canary"
        ])
    ]
    let workloads = [
        KubernetesResourceRow(id: "shop/shop-stable", cells: [
            "Namespace": "shop", "Name": "shop-stable", "Kind": "Deployment",
            "Ready": "1/1", "Selector": "app=shop"
        ]),
        KubernetesResourceRow(id: "shop/shop-canary", cells: [
            "Namespace": "shop", "Name": "shop-canary", "Kind": "Deployment",
            "Ready": "1/1", "Selector": "app=shop"
        ])
    ]
    let pods = [
        KubernetesResourceRow(id: "shop/shop-stable-aaa", cells: [
            "Namespace": "shop", "Name": "shop-stable-aaa", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=shop",
            "Owner": "ReplicaSet/shop-stable-7d9f8b6c5 -> Deployment/shop-stable",
            "PVCs": "shop-data"
        ]),
        KubernetesResourceRow(id: "shop/shop-canary-bbb", cells: [
            "Namespace": "shop", "Name": "shop-canary-bbb", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=shop,track=canary",
            "Owner": "ReplicaSet/shop-canary-5c4d3e2f1 -> Deployment/shop-canary",
            "PVCs": ""
        ])
    ]
    let ingress = [
        KubernetesResourceRow(id: "shop/shop-ingress", cells: [
            "Namespace": "shop", "Name": "shop-ingress", "Hosts": "shop.example.com",
            "TLS": "Yes", "Services": "shop-web"
        ])
    ]
    let pvcs = [
        KubernetesResourceRow(id: "shop/shop-data", cells: [
            "Namespace": "shop", "Name": "shop-data", "Status": "Bound", "Capacity": "10Gi"
        ]),
        // Exists in the namespace but nobody mounts it — must not appear.
        KubernetesResourceRow(id: "shop/orphan-data", cells: [
            "Namespace": "shop", "Name": "orphan-data", "Status": "Bound", "Capacity": "1Gi"
        ])
    ]
    let hpas = [
        KubernetesResourceRow(id: "shop/shop-hpa", cells: [
            "Namespace": "shop", "Name": "shop-hpa", "Reference": "Deployment/shop-stable",
            "MinPods": "1", "MaxPods": "5", "Replicas": "1"
        ])
    ]
    return (services, workloads, pods, ingress, pvcs, hpas)
}

private func buildSampleMap() -> ClusterTopologyGraph {
    let rows = sampleMapRows()
    return ClusterTopologyGraphBuilder.build(
        services: rows.services,
        workloads: rows.workloads,
        pods: rows.pods,
        ingress: rows.ingress,
        pvcs: rows.pvcs,
        hpas: rows.hpas
    )
}

func testMapDrawsEveryObjectExactlyOnce() {
    let graph = buildSampleMap()
    assert(Set(graph.nodes.map(\.id)).count == graph.nodes.count)
    // 2 services + 2 workloads + 2 pods + 1 ingress + 1 mounted PVC + 1 HPA.
    assert(graph.nodes.count == 9, "expected 9 nodes, got \(graph.nodes.count)")
}

func testMapKeepsAPodSharedByTwoServices() {
    let graph = buildSampleMap()
    let canaryPod = TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-canary-bbb")
    // Both `shop-web` (app=shop) and `shop-canary` (app=shop,track=canary) reach
    // this pod — the old builder dropped whichever service it visited second, so
    // the pod appeared under one of them and vanished from the other.
    for service in ["shop/shop-web", "shop/shop-canary"] {
        let id = TopologyGraphNode.id(kind: .service, rowID: service)
        assert(graph.lineage(of: id).contains(canaryPod), "\(service) cannot reach the canary pod")
    }
    // …and it is still exactly one node.
    assert(graph.nodes.filter { $0.id == canaryPod }.count == 1)
}

/// A Service whose Deployment sits at `replicas: 0` has no endpoints by design.
/// Reporting that as a failure is what turned a cluster with 87 parked workloads
/// into a map that was almost entirely red.
func testMapTreatsScaledToZeroAsIdleNotBroken() {
    let service = KubernetesResourceRow(id: "parked/api", cells: [
        "Namespace": "parked", "Name": "api", "Type": "ClusterIP", "Selector": "app=api"
    ])
    let workload = KubernetesResourceRow(id: "parked/api", cells: [
        "Namespace": "parked", "Name": "api", "Kind": "Deployment",
        "Ready": "0/0", "Selector": "app=api"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [workload], pods: [], ingress: [], pvcs: [], hpas: []
    )
    let serviceNode = graph.node(TopologyGraphNode.id(kind: .service, rowID: "parked/api"))
    let workloadNode = graph.node(TopologyGraphNode.id(kind: .workload, rowID: "parked/api"))
    assert(workloadNode?.health.isIdle == true, "got \(String(describing: workloadNode?.health))")
    assert(serviceNode?.health.isIdle == true, "got \(String(describing: serviceNode?.health))")
    assert(serviceNode?.health.needsAttention == false)
    // And the chain still holds with zero pods to bridge it.
    let targets = graph.edges.filter { $0.kind == .targets }
    assert(targets.count == 1, "expected the Service→Deployment edge to survive scale-to-zero")
}

/// A Service with a selector nothing answers, and no workload behind it either,
/// is still a real fault — idle must not swallow the genuine case.
func testMapStillFlagsAServiceWithNoBackendAtAll() {
    let service = KubernetesResourceRow(id: "n/orphan", cells: [
        "Namespace": "n", "Name": "orphan", "Type": "ClusterIP", "Selector": "app=gone"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [], pods: [], ingress: [], pvcs: [], hpas: []
    )
    assert(graph.node(TopologyGraphNode.id(kind: .service, rowID: "n/orphan"))?.health.isFailed == true)
}

func testMapUsesOwnerReferencesNotSharedLabels() {
    let graph = buildSampleMap()
    let stable = TopologyGraphNode.id(kind: .workload, rowID: "shop/shop-stable")
    let owned = graph.edgesOut(stable).filter { $0.kind == .owns }.map(\.target)
    // Both Deployments carry `app=shop`; only the ownerReference tells them apart.
    assert(owned == [TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-stable-aaa")], "got \(owned)")
}

func testMapOnlyLinksVolumesThatAreActuallyMounted() {
    let graph = buildSampleMap()
    assert(graph.node(TopologyGraphNode.id(kind: .pvc, rowID: "shop/orphan-data")) == nil)
    let mounts = graph.edges.filter { $0.kind == .mounts }
    assert(mounts.count == 1, "expected 1 mount edge, got \(mounts.count)")
    assert(mounts[0].source == TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-stable-aaa"))
}

func testMapRoutesIngressToItsNamedBackendOnly() {
    let graph = buildSampleMap()
    let routes = graph.edgesOut(TopologyGraphNode.id(kind: .ingress, rowID: "shop/shop-ingress"))
    assert(routes.count == 1)
    assert(routes[0].target == TopologyGraphNode.id(kind: .service, rowID: "shop/shop-web"))
}

func testMapLineageReachesTheWholeChain() {
    let graph = buildSampleMap()
    let lineage = graph.lineage(of: TopologyGraphNode.id(kind: .ingress, rowID: "shop/shop-ingress"))
    // Ingress → shop-web → both pods → their Deployments → the PVC and the HPA.
    assert(lineage.count == 9, "expected the whole connected component, got \(lineage.count)")
    // A pod's own lineage must not pull in unrelated namespaces' objects.
    assert(graph.lineage(of: TopologyGraphNode.id(kind: .pvc, rowID: "shop/shop-data")).count == 9)
}

/// dbt's selector syntax is how you interrogate a lineage graph. Getting the
/// direction wrong would silently answer the opposite question.
func testMapSelectorWalksTheRequestedDirection() {
    let graph = buildSampleMap()
    let web = TopologyGraphNode.id(kind: .service, rowID: "shop/shop-web")
    let ingress = TopologyGraphNode.id(kind: .ingress, rowID: "shop/shop-ingress")
    let stablePod = TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-stable-aaa")

    // Bare term: just the match.
    assert(TopologySelector("shop-web")?.resolve(in: graph) == [web])

    // `name+` reaches what depends on it, not what it depends on.
    let downstream = TopologySelector("shop-web+")?.resolve(in: graph) ?? []
    assert(downstream.contains(stablePod), "shop-web+ should reach its pods")
    assert(!downstream.contains(ingress), "shop-web+ must not walk back up to the Ingress")

    // `+name` is the mirror image.
    let upstream = TopologySelector("+shop-web")?.resolve(in: graph) ?? []
    assert(upstream.contains(ingress), "+shop-web should reach the Ingress")
    assert(!upstream.contains(stablePod), "+shop-web must not walk down to the pods")

    // `+name+` is both directions at once. Note it is *not* the same as the
    // undirected connected component: dbt's `+model+` follows dependency
    // direction, so a sibling that merely shares a downstream pod is excluded.
    let both = TopologySelector("+shop-web+")?.resolve(in: graph) ?? []
    assert(both == graph.ancestors(of: web).union(graph.descendants(of: web)))
    assert(both.contains(ingress) && both.contains(stablePod))
    assert(both.isSubset(of: graph.lineage(of: web)))

    assert(TopologySelector("   ") == nil)
    assert(TopologySelector("+")  == nil)
    assert(TopologySelector("nothing-matches-this")?.resolve(in: graph).isEmpty == true)
}

/// A namespace whose pods are owned by a CRD we cannot resolve (Argo Workflows
/// is the real case) produced 140 objects joined by 16 edges — one endless
/// column of finished pods. Grouping turns that back into a map.
func testMapGroupsInterchangeableHealthyPods() {
    let workload = KubernetesResourceRow(id: "run/runner", cells: [
        "Namespace": "run", "Name": "runner", "Kind": "Deployment", "Ready": "20/20", "Selector": "app=runner"
    ])
    var pods: [KubernetesResourceRow] = (0..<20).map { i in
        KubernetesResourceRow(id: "run/runner-\(i)", cells: [
            "Namespace": "run", "Name": "runner-\(i)", "Status": "Running", "Ready": "1/1",
            "Restarts": "0", "Labels": "app=runner", "Owner": "Deployment/runner"
        ])
    }
    // One of them is broken.
    pods.append(KubernetesResourceRow(id: "run/runner-bad", cells: [
        "Namespace": "run", "Name": "runner-bad", "Status": "CrashLoopBackOff", "Ready": "0/1",
        "Restarts": "9", "Labels": "app=runner", "Owner": "Deployment/runner"
    ]))

    let raw = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    assert(raw.nodes.count == 22, "expected workload + 21 pods, got \(raw.nodes.count)")

    let grouped = TopologyRelevanceProjector.project(
        raw,
        options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    ).graph
    // workload + five visible healthy pods + one group + the crash-looping pod.
    assert(grouped.nodes.count == 8, "expected 8 nodes, got \(grouped.nodes.count)")

    let group = grouped.nodes.first { $0.kind == .podGroup }
    assert(group?.name == "15 pods", "got \(String(describing: group?.name))")

    // The broken pod must survive as its own clickable node.
    let broken = grouped.nodes.first { $0.kind == .pod && $0.health.isFailed }
    assert(broken?.name == "runner-bad")
    assert(broken?.health.isFailed == true)

    // And the chain still holds: the workload reaches both.
    let workloadID = TopologyGraphNode.id(kind: .workload, rowID: "run/runner")
    assert(grouped.edgesOut(workloadID).count == 7, "workload should manage visible pods, the group, and the broken pod")
}

/// Pods with different parents must never merge, or the map would claim a
/// relationship that does not exist.
func testMapNeverGroupsPodsWithDifferentParents() {
    let workloads = ["a", "b"].map { name in
        KubernetesResourceRow(id: "run/\(name)", cells: [
            "Namespace": "run", "Name": name, "Kind": "Deployment", "Ready": "8/8", "Selector": "app=\(name)"
        ])
    }
    let pods = ["a", "b"].flatMap { owner in
        (0..<8).map { i in
            KubernetesResourceRow(id: "run/\(owner)-\(i)", cells: [
                "Namespace": "run", "Name": "\(owner)-\(i)", "Status": "Running", "Ready": "1/1",
                "Restarts": "0", "Labels": "app=\(owner)", "Owner": "Deployment/\(owner)"
            ])
        }
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: workloads, pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let grouped = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    ).graph

    assert(grouped.nodes.filter { $0.kind == .podGroup }.count == 2, "one group per owner")
    for workload in workloads {
        let id = TopologyGraphNode.id(kind: .workload, rowID: workload.id)
        assert(grouped.edgesOut(id).count == 6, "\(workload.name) should manage five pods and its own group")
    }
}

/// Below the threshold nothing is hidden — a three-replica Deployment still
/// shows its three pods.
func testMapLeavesSmallPodSetsAlone() {
    let workload = KubernetesResourceRow(id: "run/small", cells: [
        "Namespace": "run", "Name": "small", "Kind": "Deployment", "Ready": "3/3", "Selector": "app=small"
    ])
    let pods = (0..<3).map { i in
        KubernetesResourceRow(id: "run/small-\(i)", cells: [
            "Namespace": "run", "Name": "small-\(i)", "Status": "Running", "Ready": "1/1",
            "Restarts": "0", "Labels": "app=small", "Owner": "Deployment/small"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let grouped = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    ).graph
    assert(grouped.nodes.filter { $0.kind == .podGroup }.isEmpty)
    assert(grouped.nodes.filter { $0.kind == .pod }.count == 3)
}

func testMapLayoutFlowsLeftToRight() {
    let graph = buildSampleMap()
    let layout = TopologyGraphLayout.layout(graph)
    assert(layout.positions.count == graph.nodes.count)
    for edge in graph.edges {
        guard let source = layout.positions[edge.source], let target = layout.positions[edge.target] else {
            assertionFailure("unpositioned edge \(edge.id)")
            continue
        }
        assert(source.x < target.x, "edge \(edge.id) points backwards")
    }
    assert(layout.size.width > 0 && layout.size.height > 0)
}

func testMapLayoutTerminatesOnACycle() {
    // A malformed graph must squash a column, not hang the app.
    let a = TopologyGraphNode(id: "a", kind: .service, name: "a", namespace: "n", subtitle: "", health: .healthy, row: KubernetesResourceRow(id: "n/a", cells: [:]))
    let b = TopologyGraphNode(id: "b", kind: .service, name: "b", namespace: "n", subtitle: "", health: .healthy, row: KubernetesResourceRow(id: "n/b", cells: [:]))
    let cyclic = ClusterTopologyGraph(
        nodes: [a, b],
        edges: [
            TopologyGraphEdge(source: "a", target: "b", kind: .routes),
            TopologyGraphEdge(source: "b", target: "a", kind: .routes)
        ]
    )
    assert(TopologyGraphLayout.layout(cyclic).positions.count == 2)
}

func testTopologyHitIndexMatchesRepresentativeLayoutFrames() {
    let graph = buildSampleMap()
    let layout = TopologyGraphLayout.layout(graph)
    let index = TopologyHitIndex(layout: layout)

    for node in graph.nodes {
        guard let frame = layout.frame(node.id) else {
            assertionFailure("missing frame for \(node.id)")
            continue
        }
        let samples = [
            CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5),
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.maxX - 0.5, y: frame.maxY - 0.5)
        ]
        for point in samples {
            let linear = graph.nodes.first {
                layout.frame($0.id)?.contains(point) == true
            }?.id
            assert(index.nodeID(at: point) == linear, "hit mismatch at \(point)")
        }
    }

    for point in [
        CGPoint.zero,
        CGPoint(x: layout.size.width + 1, y: layout.size.height + 1),
        CGPoint(x: TopologyGraphLayout.padding - 1, y: TopologyGraphLayout.padding)
    ] {
        let linear = graph.nodes.first {
            layout.frame($0.id)?.contains(point) == true
        }?.id
        assert(index.nodeID(at: point) == linear, "empty-space mismatch at \(point)")
    }
}

func testTopologyHitIndexMatchesLargeSyntheticLayout() {
    var layout = TopologyGraphLayout.Result()
    let columnStride = TopologyGraphLayout.nodeWidth + TopologyGraphLayout.columnGap
    let rowStride = TopologyGraphLayout.nodeHeight + TopologyGraphLayout.rowGap
    for column in 0..<12 {
        for row in 0..<180 {
            layout.positions["\(column)-\(row)"] = CGPoint(
                x: TopologyGraphLayout.padding + CGFloat(column) * columnStride,
                y: TopologyGraphLayout.padding + CGFloat(row) * rowStride
            )
        }
    }
    let index = TopologyHitIndex(layout: layout)
    let orderedIDs = layout.positions.keys.sorted()

    for column in 0..<12 {
        for row in stride(from: 0, to: 180, by: 7) {
            let origin = layout.positions["\(column)-\(row)"]!
            for offset in [
                CGPoint(x: 1, y: 1),
                CGPoint(x: TopologyGraphLayout.nodeWidth / 2, y: TopologyGraphLayout.nodeHeight / 2),
                CGPoint(x: TopologyGraphLayout.nodeWidth - 1, y: TopologyGraphLayout.nodeHeight - 1),
                CGPoint(x: TopologyGraphLayout.nodeWidth + 1, y: TopologyGraphLayout.nodeHeight / 2)
            ] {
                let point = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
                let linear = orderedIDs.first {
                    layout.frame($0)?.contains(point) == true
                }
                assert(index.nodeID(at: point) == linear, "synthetic hit mismatch at \(point)")
            }
        }
    }

    assert(index.neighbor(of: "5-80", toward: .up) == "5-79")
    assert(index.neighbor(of: "5-80", toward: .down) == "5-81")
    assert(index.neighbor(of: "5-80", toward: .left) == "4-80")
    assert(index.neighbor(of: "5-80", toward: .right) == "6-80")
}

/// An empty map and an identifier that was never laid out are both ordinary
/// states — a namespace still loading, or a caret left on a node the projection
/// has since folded into a group.
func testTopologyHitIndexHandlesEmptyLayoutsAndUnknownNodes() {
    let empty = TopologyHitIndex(layout: TopologyGraphLayout.Result())
    assert(empty.orderedNodeIDs.isEmpty)
    assert(empty.frame(of: "anything") == nil)
    assert(empty.nodeID(at: .zero) == nil)
    assert(empty.nodeID(at: CGPoint(x: 120, y: 80)) == nil)

    var single = TopologyGraphLayout.Result()
    single.positions["only"] = CGPoint(x: 10, y: 10)
    let index = TopologyHitIndex(layout: single)
    for direction in [
        TopologyHitIndex.Direction.left, .right, .up, .down
    ] {
        assert(index.neighbor(of: "missing", toward: direction) == nil)
        assert(index.neighbor(of: "only", toward: direction) == nil, "a lone node has no neighbour")
    }
    assert(index.orderedNodeIDs == ["only"])
    assert(index.frame(of: "only")?.origin == CGPoint(x: 10, y: 10))
}

/// Arrow keys stop at the edges of the map rather than wrapping, so the ends of
/// every column and row must report no neighbour.
func testTopologyHitIndexStopsAtLayoutBoundaries() {
    var layout = TopologyGraphLayout.Result()
    let columnStride = TopologyGraphLayout.nodeWidth + TopologyGraphLayout.columnGap
    let rowStride = TopologyGraphLayout.nodeHeight + TopologyGraphLayout.rowGap
    for column in 0..<3 {
        for row in 0..<4 {
            layout.positions["c\(column)r\(row)"] = CGPoint(
                x: TopologyGraphLayout.padding + CGFloat(column) * columnStride,
                y: TopologyGraphLayout.padding + CGFloat(row) * rowStride
            )
        }
    }
    let index = TopologyHitIndex(layout: layout)

    assert(index.orderedNodeIDs.first == "c0r0", "reading order starts at the top of the first column")
    assert(index.orderedNodeIDs.prefix(4) == ["c0r0", "c0r1", "c0r2", "c0r3"])
    assert(index.orderedNodeIDs.count == 12)

    assert(index.neighbor(of: "c0r0", toward: .up) == nil)
    assert(index.neighbor(of: "c0r0", toward: .left) == nil)
    assert(index.neighbor(of: "c2r3", toward: .down) == nil)
    assert(index.neighbor(of: "c2r3", toward: .right) == nil)
    assert(index.neighbor(of: "c1r2", toward: .up) == "c1r1")
    assert(index.neighbor(of: "c1r2", toward: .down) == "c1r3")
    assert(index.neighbor(of: "c1r2", toward: .left) == "c0r2")
    assert(index.neighbor(of: "c1r2", toward: .right) == "c2r2")
}

/// `CGRect.contains` excludes its far edges. The index has to agree with it
/// exactly, or a click one pixel inside a pill would select a different node
/// than the tooltip under the same pixel describes.
func testTopologyHitIndexAgreesWithFrameContainmentOnEdges() {
    let graph = buildSampleMap()
    let layout = TopologyGraphLayout.layout(graph)
    let index = TopologyHitIndex(layout: layout)

    var probes: [CGPoint] = []
    for id in layout.positions.keys.sorted() {
        guard let frame = layout.frame(id) else { continue }
        probes.append(contentsOf: [
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.maxX - 0.01, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.maxY - 0.01),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.minY),
            // The gutter between two columns, and between two rows.
            CGPoint(x: frame.maxX + TopologyGraphLayout.columnGap / 2, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.maxY + TopologyGraphLayout.rowGap / 2)
        ])
    }

    for point in probes {
        let linear = layout.positions.keys.sorted().first {
            layout.frame($0)?.contains(point) == true
        }
        assert(index.nodeID(at: point) == linear, "edge disagreement at \(point)")
    }
}

func testCompletedPodsAreIdleAndNotActiveServiceEndpoints() {
    let service = KubernetesResourceRow(id: "jobs/report", cells: [
        "Namespace": "jobs", "Name": "report", "Selector": "app=report"
    ])
    let workload = KubernetesResourceRow(id: "jobs/report", cells: [
        "Namespace": "jobs", "Name": "report", "Kind": "Deployment",
        "Ready": "0/1", "Selector": "app=report"
    ])
    let pod = KubernetesResourceRow(id: "jobs/report-finished", cells: [
        "Namespace": "jobs", "Name": "report-finished", "Status": "Succeeded",
        "Ready": "0/1", "Restarts": "0", "Labels": "app=report",
        "Owner": "Deployment/report"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [workload], pods: [pod],
        ingress: [], pvcs: [], hpas: []
    )
    let podID = TopologyGraphNode.id(kind: .pod, rowID: pod.id)
    let serviceID = TopologyGraphNode.id(kind: .service, rowID: service.id)
    assert(graph.node(podID)?.health.isIdle == true)
    assert(graph.node(serviceID)?.subtitle.contains("0 endpoints") == true)
    assert(graph.edgesOut(serviceID).contains { $0.kind == .targets })
    assert(!graph.edgesOut(serviceID).contains { $0.kind == .selects && $0.target == podID })
}

func testTerminalBarePodsNeverReceiveServiceEndpointEdges() {
    let service = KubernetesResourceRow(id: "batch/results", cells: [
        "Namespace": "batch", "Name": "results", "Selector": "job=report"
    ])
    let terminal = KubernetesResourceRow(id: "batch/report-finished", cells: [
        "Namespace": "batch", "Name": "report-finished", "Status": "Completed",
        "Ready": "0/1", "Labels": "job=report", "Owner": "Job/report"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [], pods: [terminal],
        ingress: [], pvcs: [], hpas: []
    )
    let serviceID = TopologyGraphNode.id(kind: .service, rowID: service.id)
    assert(graph.edgesOut(serviceID).isEmpty)
    assert(graph.node(serviceID)?.subtitle.contains("0 endpoints") == true)
}

func testServicePreservesTargetedWorkloadFailureWithoutActivePods() {
    let service = KubernetesResourceRow(id: "n/api", cells: [
        "Namespace": "n", "Name": "api", "Selector": "app=api"
    ])
    let failedWorkload = KubernetesResourceRow(id: "n/api", cells: [
        "Namespace": "n", "Name": "api", "Kind": "Deployment",
        "Ready": "0/2", "Selector": "app=api"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [failedWorkload], pods: [],
        ingress: [], pvcs: [], hpas: []
    )
    let serviceHealth = graph.node(
        TopologyGraphNode.id(kind: .service, rowID: service.id)
    )?.health
    assert(serviceHealth?.isFailed == true)
    if let serviceHealth, case .failed(let reason, _, _, _) = serviceHealth {
        assert(reason.contains("Workload Down"))
    }
}

func testUnresolvedOwnersNeverCreateWorkloadOwnershipEdges() {
    let actual = KubernetesResourceRow(id: "n/actual", cells: [
        "Namespace": "n", "Name": "actual", "Kind": "Deployment",
        "Ready": "1/1", "Selector": "app=shared"
    ])
    let other = KubernetesResourceRow(id: "n/other", cells: [
        "Namespace": "n", "Name": "other", "Kind": "Deployment",
        "Ready": "1/1", "Selector": "app=shared"
    ])
    let resolved = KubernetesResourceRow(id: "n/resolved", cells: [
        "Namespace": "n", "Name": "resolved", "Status": "Running", "Ready": "1/1",
        "Labels": "app=shared", "Owner": "Deployment/actual"
    ])
    let unresolved = KubernetesResourceRow(id: "n/unresolved", cells: [
        "Namespace": "n", "Name": "unresolved", "Status": "Running", "Ready": "1/1",
        "Labels": "app=shared", "Owner": "Job/external-controller"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [actual, other], pods: [resolved, unresolved],
        ingress: [], pvcs: [], hpas: []
    )
    let resolvedID = TopologyGraphNode.id(kind: .pod, rowID: resolved.id)
    let actualEdges = graph.edgesOut(TopologyGraphNode.id(kind: .workload, rowID: actual.id))
    let otherEdges = graph.edgesOut(TopologyGraphNode.id(kind: .workload, rowID: other.id))
    assert(actualEdges.contains { $0.target == resolvedID })
    assert(!otherEdges.contains { $0.target == resolvedID })
    let unresolvedID = TopologyGraphNode.id(kind: .pod, rowID: unresolved.id)
    assert(!actualEdges.contains { $0.target == unresolvedID })
    assert(!otherEdges.contains { $0.target == unresolvedID })
    assert(graph.edgesIn(unresolvedID).isEmpty, "an unresolved owner must remain unattached without a Service")
}

func testTopologyProjectionCapsGroupsAndExpandsInBatches() {
    let workload = KubernetesResourceRow(id: "scale/work", cells: [
        "Namespace": "scale", "Name": "work", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=work"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "scale/work-\(index)", cells: [
            "Namespace": "scale", "Name": "work-\(index)", "Status": "Running",
            "Ready": "1/1", "Labels": "app=work", "Owner": "Deployment/work"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let options = TopologyProjectionOptions(
        budget: 100, perParentCap: 5, sampleNameLimit: 3, expansionBatchSize: 20
    )
    let initial = TopologyRelevanceProjector.project(source, options: options)
    let group = initial.groupsByNodeID.values.first { $0.kind == .healthyPods }
    assert(initial.graph.nodes.count == 7, "workload + five pods + one group")
    assert(group?.hiddenCount == 55)
    assert(group?.sampleNames.count == 3)

    var expansion = TopologyExpansionState()
    expansion.expand(group!.nodeID)
    let expanded = TopologyRelevanceProjector.project(
        source, options: options, expansion: expansion
    )
    assert(expanded.graph.nodes.count == 27, "one expansion must reveal exactly 20 pods")
    assert(expanded.groupsByNodeID[group!.nodeID]?.hiddenCount == 35)
}

func testTopologyProjectionKeepsHiddenTerminalPodsSearchable() {
    let pods = (0..<8).map { index in
        KubernetesResourceRow(id: "batch/job-\(index)", cells: [
            "Namespace": "batch", "Name": "job-\(index)", "Status": "Completed",
            "Ready": "0/1", "Labels": "job=batch", "Owner": "Job/nightly"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 50, sampleNameLimit: 2)
    )
    assert(projection.graph.nodes.count == 1)
    assert(projection.graph.nodes[0].kind == .terminalGroup)
    let hiddenID = TopologyGraphNode.id(kind: .pod, rowID: "batch/job-7")
    assert(projection.searchNodeIDs(matching: "job-7") == [hiddenID])
    assert(projection.materializing(nodeIDs: [hiddenID]).node(hiddenID) != nil)

    let focused = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 50),
        focusedNodeID: hiddenID
    )
    assert(focused.graph.node(hiddenID) != nil, "focus must outrank terminal grouping")
    assert(TopologyProjectionOptions(budget: 10_000).budget == TopologyProjectionOptions.hardCeiling)
}

func testTopologySearchOutranksProjectionBudget() {
    let pods = (0..<20).map { index in
        KubernetesResourceRow(id: "search/task-\(index)", cells: [
            "Namespace": "search", "Name": "task-\(index)", "Status": "Succeeded",
            "Ready": "0/1", "Owner": "Job/archive"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let searchedID = TopologyGraphNode.id(kind: .pod, rowID: "search/task-19")
    let projection = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 1),
        searchNodeIDs: [searchedID]
    )
    assert(projection.graph.nodes.map(\.id) == [searchedID])
}

func testTopologyMaterializationReplacesSyntheticMembershipCleanly() {
    let workload = KubernetesResourceRow(id: "batch/nightly", cells: [
        "Namespace": "batch", "Name": "nightly", "Kind": "Deployment",
        "Ready": "0/0", "Selector": "job=nightly"
    ])
    let pods = (0..<10).map { index in
        KubernetesResourceRow(id: "batch/nightly-\(index)", cells: [
            "Namespace": "batch", "Name": "nightly-\(index)", "Status": "Completed",
            "Ready": "0/1", "Labels": "job=nightly", "Owner": "Deployment/nightly"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 50)
    )
    let materializedID = TopologyGraphNode.id(kind: .pod, rowID: "batch/nightly-9")
    let materialized = projection.materializing(nodeIDs: [materializedID])
    let workloadID = TopologyGraphNode.id(kind: .workload, rowID: workload.id)
    let owns = materialized.edgesOut(workloadID).filter { $0.kind == .owns }
    assert(owns.filter { $0.target == materializedID }.count == 1)
    assert(owns.filter { materialized.node($0.target)?.kind == .terminalGroup }.count == 1)
    assert(Set(owns.map(\.id)).count == owns.count)
}

func testTopologyEligibleCountsUseUnprojectedFilteredObjects() {
    let active = KubernetesResourceRow(id: "count/active", cells: [
        "Namespace": "count", "Name": "active", "Status": "Running", "Ready": "1/1"
    ])
    let inactive = KubernetesResourceRow(id: "count/inactive", cells: [
        "Namespace": "count", "Name": "inactive", "Status": "Completed", "Ready": "0/1"
    ])
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: [active, inactive],
        ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 10)
    )

    assert(projection.sourceNodeCount == 2)
    assert(projection.eligibleSourceNodeIDs(TopologyMapFilter()).count == 1)
    assert(projection.eligibleSourceNodeIDs(
        TopologyMapFilter(searchText: "inactive", includesInactive: true)
    ) == [TopologyGraphNode.id(kind: .pod, rowID: inactive.id)])
}

/// A namespace of grouped pods. Searching for one that the projection folded
/// into a group must not be answered with "No match": the object exists, the
/// map just has not materialised it yet.
func testMapSnapshotWaitsForGroupedMatchInsteadOfClaimingNoMatch() {
    let workload = KubernetesResourceRow(id: "run/fleet", cells: [
        "Namespace": "run", "Name": "fleet", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=fleet"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "run/fleet-\(index)", cells: [
            "Namespace": "run", "Name": "fleet-\(index)", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=fleet",
            "Owner": "Deployment/fleet"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    )

    let hidden = TopologyMapSnapshot(
        projected: projection.graph,
        projection: projection,
        filter: TopologyMapFilter(searchText: "fleet-59")
    )
    assert(hidden.graph.isEmpty, "the grouped pod is not on the map yet")
    assert(hidden.eligibleCount == 1, "but the source has exactly one match")
    assert(hidden.vacancy == .awaitingProjection, "got \(hidden.vacancy)")

    let materialized = TopologyMapSnapshot(
        projected: projection.materializing(nodeIDs: hidden.eligibleSourceNodeIDs),
        projection: projection,
        filter: TopologyMapFilter(searchText: "fleet-59")
    )
    assert(materialized.vacancy == .none)
    assert(materialized.visibleRealCount == 1)

    let absent = TopologyMapSnapshot(
        projected: projection.graph,
        projection: projection,
        filter: TopologyMapFilter(searchText: "no-such-object")
    )
    assert(absent.vacancy == .noSearchMatch, "got \(absent.vacancy)")
}

/// The toolbar's three numbers have to add up: what is drawn, what the filters
/// match, and what grouping took away.
func testMapSnapshotCountsDrawnGroupedAndEligibleSeparately() {
    let workload = KubernetesResourceRow(id: "run/fleet", cells: [
        "Namespace": "run", "Name": "fleet", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=fleet"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "run/fleet-\(index)", cells: [
            "Namespace": "run", "Name": "fleet-\(index)", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=fleet",
            "Owner": "Deployment/fleet"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    )
    let snapshot = TopologyMapSnapshot(
        projected: projection.graph, projection: projection, filter: TopologyMapFilter()
    )

    assert(snapshot.vacancy == .none)
    assert(snapshot.syntheticGroupCount == 1)
    assert(snapshot.visibleRealCount == 6, "workload plus five pods, got \(snapshot.visibleRealCount)")
    assert(snapshot.eligibleCount == 61, "got \(snapshot.eligibleCount)")
    assert(snapshot.projectionHiddenCount == 55, "got \(snapshot.projectionHiddenCount)")
}

/// A pod going CrashLoopBackOff must not move the map. Structure decides the
/// layout; name and health only decide what is painted on it.
func testTopologyIdentitySeparatesStructureFromPresentation() {
    func pod(_ name: String, health: TopologyNodeHealthState) -> TopologyGraphNode {
        TopologyGraphNode(
            id: "pod/ns/\(name)",
            kind: .pod,
            name: name,
            namespace: "ns",
            subtitle: health.summaryTitle,
            health: health,
            row: KubernetesResourceRow(id: "ns/\(name)", cells: ["Namespace": "ns", "Name": name])
        )
    }
    let edge = TopologyGraphEdge(source: "pod/ns/a", target: "pod/ns/b", kind: .owns)
    let healthy = ClusterTopologyGraph(
        nodes: [pod("a", health: .healthy), pod("b", health: .healthy)], edges: [edge]
    )
    let crashing = ClusterTopologyGraph(
        nodes: [
            pod("a", health: .healthy),
            pod("b", health: .failed(
                reason: "CrashLoopBackOff", details: "", exitCode: 1, restartCount: 9
            ))
        ],
        edges: [edge]
    )

    assert(TopologyStructuralIdentity(healthy) == TopologyStructuralIdentity(crashing),
           "health must not force a relayout")
    assert(TopologyPresentationIdentity(healthy) != TopologyPresentationIdentity(crashing),
           "health must still force a redraw")

    let disconnected = ClusterTopologyGraph(nodes: healthy.nodes, edges: [])
    assert(TopologyStructuralIdentity(healthy) != TopologyStructuralIdentity(disconnected))

    // Node order is an accident of how the graph was assembled, not a change.
    let reordered = ClusterTopologyGraph(nodes: healthy.nodes.reversed(), edges: [edge])
    assert(TopologyStructuralIdentity(healthy) == TopologyStructuralIdentity(reordered))
    assert(TopologyPresentationIdentity(healthy) == TopologyPresentationIdentity(reordered))
}

/// Arrow keys follow the lineage, not the paint: right from a Service reaches
/// the workload it selects, and the first press with no caret lands rather than
/// steps.
func testTopologyKeyboardNavigationFollowsEdgesBeforeGeometry() {
    let service = KubernetesResourceRow(id: "run/api", cells: [
        "Namespace": "run", "Name": "api", "Type": "ClusterIP", "Selector": "app=api"
    ])
    let workload = KubernetesResourceRow(id: "run/api", cells: [
        "Namespace": "run", "Name": "api", "Kind": "Deployment",
        "Ready": "1/1", "Selector": "app=api"
    ])
    let pod = KubernetesResourceRow(id: "run/api-0", cells: [
        "Namespace": "run", "Name": "api-0", "Status": "Running", "Ready": "1/1",
        "Restarts": "0", "Labels": "app=api", "Owner": "Deployment/api"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [workload], pods: [pod],
        ingress: [], pvcs: [], hpas: []
    )
    let layout = TopologyGraphLayout.layout(graph)
    let index = TopologyHitIndex(layout: layout)

    let landing = TopologyKeyboardNavigation.next(
        from: nil, toward: .right, in: graph, layout: layout, hitIndex: index
    )
    assert(landing == index.orderedNodeIDs.first, "the first press must land, not step")

    let serviceID = graph.nodes.first { $0.kind == .service }!.id
    let workloadID = graph.nodes.first { $0.kind == .workload }!.id
    let right = TopologyKeyboardNavigation.next(
        from: serviceID, toward: .right, in: graph, layout: layout, hitIndex: index
    )
    assert(right == workloadID, "right from a service must reach what it selects, got \(right ?? "nil")")

    let back = TopologyKeyboardNavigation.next(
        from: workloadID, toward: .left, in: graph, layout: layout, hitIndex: index
    )
    assert(back == serviceID, "left must walk back up the edge, got \(back ?? "nil")")

    // Nothing is above or below anything in a single chain, so vertical presses
    // have nowhere to go rather than wrapping to an unrelated column.
    assert(TopologyKeyboardNavigation.next(
        from: workloadID, toward: .up, in: graph, layout: layout, hitIndex: index
    ) == nil)
}

/// The three lengths describe one map. The short and medium forms exist so a
/// narrow toolbar can stop printing the long one — not so they can round the
/// numbers into something friendlier than the truth.
func testTopologyCountSummaryAgreesAtEveryLength() {
    let grouped = TopologyCountSummary(
        visibleRealCount: 6,
        syntheticGroupCount: 1,
        eligibleCount: 61,
        projectionHiddenCount: 55
    )
    assert(grouped.full == "Showing 6 real + 1 group · 61 filter-eligible · 55 grouped/omitted",
           "got \(grouped.full)")
    assert(grouped.medium == "6 of 61 shown", "got \(grouped.medium)")
    assert(grouped.short == "6/61", "got \(grouped.short)")

    // Nothing hidden: a ratio of a number to itself invites the reader to look
    // for the missing objects, so both short forms drop the denominator.
    let whole = TopologyCountSummary(
        visibleRealCount: 12,
        syntheticGroupCount: 0,
        eligibleCount: 12,
        projectionHiddenCount: 0
    )
    assert(whole.full == "Showing 12 real · 12 filter-eligible", "got \(whole.full)")
    assert(whole.medium == "12 shown", "got \(whole.medium)")
    assert(whole.short == "12", "got \(whole.short)")

    let plural = TopologyCountSummary(
        visibleRealCount: 2,
        syntheticGroupCount: 3,
        eligibleCount: 40,
        projectionHiddenCount: 38
    )
    assert(plural.full.contains("3 groups"), "got \(plural.full)")
}

/// Whatever the snapshot counted is what the toolbar says, at every length.
func testTopologyCountSummaryFollowsTheSnapshot() {
    let workload = KubernetesResourceRow(id: "run/fleet", cells: [
        "Namespace": "run", "Name": "fleet", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=fleet"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "run/fleet-\(index)", cells: [
            "Namespace": "run", "Name": "fleet-\(index)", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=fleet",
            "Owner": "Deployment/fleet"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    )
    let snapshot = TopologyMapSnapshot(
        projected: projection.graph, projection: projection, filter: TopologyMapFilter()
    )
    let summary = TopologyCountSummary(snapshot)

    assert(summary.short == "\(snapshot.visibleRealCount)/\(snapshot.eligibleCount)",
           "got \(summary.short)")
    assert(summary.full.contains("\(snapshot.projectionHiddenCount) grouped/omitted"),
           "got \(summary.full)")
}

func testTopologyBuilderStopsDuringLargeInputCancellation() {
    let pods = (0..<1_000).map { index in
        KubernetesResourceRow(id: "cancel/pod-\(index)", cells: [
            "Namespace": "cancel", "Name": "pod-\(index)", "Status": "Running",
            "Ready": "1/1", "Labels": "app=cancel"
        ])
    }
    var checks = 0
    let graph = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: pods,
        ingress: [], pvcs: [], hpas: [],
        isCancelled: {
            checks += 1
            return checks > 10
        }
    )
    assert(graph.isEmpty)
    assert(checks < pods.count, "cancellation should stop before traversing all rows")
}

try testHygieneScoreRewardsFullyDeclaredHealthyPods()
try testHygieneScoreReadsRawRequestsNotDisplayCells()
try testHygieneScoreIsPodsOnly()
testTopologyFailureEvaluatorPodFailures()
testTopologyFailureEvaluatorServiceFailures()
testMapDrawsEveryObjectExactlyOnce()
testMapKeepsAPodSharedByTwoServices()
testMapTreatsScaledToZeroAsIdleNotBroken()
testMapStillFlagsAServiceWithNoBackendAtAll()
testMapUsesOwnerReferencesNotSharedLabels()
testMapOnlyLinksVolumesThatAreActuallyMounted()
testMapRoutesIngressToItsNamedBackendOnly()
testMapLineageReachesTheWholeChain()
testMapSelectorWalksTheRequestedDirection()
testMapGroupsInterchangeableHealthyPods()
testMapNeverGroupsPodsWithDifferentParents()
testMapLeavesSmallPodSetsAlone()
testMapLayoutFlowsLeftToRight()
testMapLayoutTerminatesOnACycle()
testTopologyHitIndexMatchesRepresentativeLayoutFrames()
testTopologyHitIndexMatchesLargeSyntheticLayout()
testTopologyHitIndexHandlesEmptyLayoutsAndUnknownNodes()
testTopologyHitIndexStopsAtLayoutBoundaries()
testTopologyHitIndexAgreesWithFrameContainmentOnEdges()
testCompletedPodsAreIdleAndNotActiveServiceEndpoints()
testTerminalBarePodsNeverReceiveServiceEndpointEdges()
testServicePreservesTargetedWorkloadFailureWithoutActivePods()
testUnresolvedOwnersNeverCreateWorkloadOwnershipEdges()
testTopologyProjectionCapsGroupsAndExpandsInBatches()
testTopologyProjectionKeepsHiddenTerminalPodsSearchable()
testTopologySearchOutranksProjectionBudget()
testTopologyMaterializationReplacesSyntheticMembershipCleanly()
testTopologyEligibleCountsUseUnprojectedFilteredObjects()
testMapSnapshotWaitsForGroupedMatchInsteadOfClaimingNoMatch()
testMapSnapshotCountsDrawnGroupedAndEligibleSeparately()
testTopologyIdentitySeparatesStructureFromPresentation()
testTopologyKeyboardNavigationFollowsEdgesBeforeGeometry()
testTopologyCountSummaryAgreesAtEveryLength()
testTopologyCountSummaryFollowsTheSnapshot()
testTopologyBuilderStopsDuringLargeInputCancellation()

print("CTXCoreTests passed")
