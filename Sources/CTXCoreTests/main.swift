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
        .services: true,
        .ingress: true,
        .events: true,
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
        ["aws", "sso", "login", "--profile", "dev"],
        ["gcloud", "auth", "login", "--update-adc", "--configuration", "dev"],
        ["az", "login", "--tenant", "tenant-123"],
        ["az", "account", "set", "--subscription", "sub-123"],
        ["aws", "sso", "logout", "--profile", "dev"],
        ["gcloud", "auth", "revoke", "dev@example.com"],
        ["az", "logout"],
        ["aws", "sts", "get-caller-identity", "--profile", "dev", "--output", "json"],
        ["gcloud", "auth", "print-access-token", "--configuration", "dev"],
        ["az", "account", "show", "--subscription", "sub-123", "--output", "json"],
        ["kubectl", "config", "get-contexts", "dev-context", "--output", "name"],
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
    let deadline = Date().addingTimeInterval(1)
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
    let deadline = Date().addingTimeInterval(1)
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
    let deadline = Date().addingTimeInterval(1)
    while !(await runner.allCommands()).contains(where: { $0.contains("use-context") }), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let commands = await runner.allCommands()
    assert(commands.contains { $0.contains("use-context") && $0.contains("team-c") }, "Connect on a never-yet-verified kube context must still run the real kubectl context switch, not just update in-app bookkeeping")
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
    let scannedPaths = [
        root.appendingPathComponent("Sources"),
        root.appendingPathComponent("README.md"),
        root.appendingPathComponent("AGENTS.md"),
        root.appendingPathComponent("SECURITY.md"),
        root.appendingPathComponent("DESIGN_SYSTEM.md"),
        root.appendingPathComponent("KUBERNETES_WORKSPACE.md"),
        root.appendingPathComponent("ROADMAP.md"),
        root.appendingPathComponent("CONTRIBUTING.md")
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
try testCTXUpdateServiceParsesReleaseAndComparesVersions()
try testAWSSessionExpirationServicePrefersCredentialsExpiry()
try testAWSCredentialServiceParsesIdentityAndCredentials()
try testCloudProfilePersistenceServiceWritesAWSProfile()
try await testProfileStoreAddsAWSProfileIntoVisibleStateImmediately()
try testProfileStoreAddsCloudProfilesIntoTargetFolders()
try await testProfileStoreKeepsKubeContextTargetFolderBeforeDiscoveryCatchesUp()
try await testProfileStorePromptsForFolderWhenCreatedWithoutOne()
try await testProfileStoreTargetsContextsOwnKubeconfigFileNotJustThePrimaryOne()
try await testProfileStoreLoginActuallySwitchesKubeContextEvenWhenStatusWasUnknown()
try testCloudFolderPreferencesStoreRoundTripsState()
try testOpenSourceFixturesStayGeneric()

print("CTXCoreTests passed")
