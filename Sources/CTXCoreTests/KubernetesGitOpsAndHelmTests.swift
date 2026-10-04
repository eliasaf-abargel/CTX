import CTXCore
import Foundation

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

/// Secret-backed variables must expose their reference and never a value — CTX
/// does not read the Secret at all. The old inspector printed invented values like
/// "secret123" that looked entirely real.

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


func runKubernetesGitOpsAndHelmTests() async throws {
    try await testGitOpsIsReadClusterWideRegardlessOfSelectedNamespace()
    try await testGitOpsPartialFailureKeepsAppsAndReportsIncompleteness()
    try await testGitOpsReadsControllersConcurrently()
    try testShortRevisionKeepsBranchAndLeavesVersionsIntact()
    try await testHelmListAsksForEveryReleaseState()
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
}
