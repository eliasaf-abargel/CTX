import CTXCore
import Foundation

func testKubernetesResourceParserBatchParsing() {
    let rawJSON = """
    {
        "kind": "List",
        "apiVersion": "v1",
        "items": [
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {"name": "frontend-svc", "namespace": "prod"},
                "spec": {"type": "ClusterIP", "clusterIP": "10.0.0.1", "ports": [{"port": 80}]}
            },
            {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {"name": "frontend-deploy", "namespace": "prod"},
                "spec": {"replicas": 3},
                "status": {"replicas": 3, "readyReplicas": 3, "availableReplicas": 3}
            },
            {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {"name": "frontend-pod-1", "namespace": "prod"},
                "spec": {"containers": [{"name": "web", "image": "nginx:1.25"}]},
                "status": {"phase": "Running", "containerStatuses": [{"ready": true, "restartCount": 0}]}
            }
        ]
    }
    """
    let kinds: [KubernetesResourceKind] = [.services, .workloads, .pods]
    let parsed = KubernetesResourceParser.parseBatch(stdout: rawJSON, requestedKinds: kinds)
    assert(parsed != nil)
    assert(parsed?[.services]?.rows.count == 1)
    assert(parsed?[.services]?.rows.first?.cells["Name"] == "frontend-svc")
    assert(parsed?[.workloads]?.rows.count == 1)
    assert(parsed?[.workloads]?.rows.first?.cells["Name"] == "frontend-deploy")
    assert(parsed?[.pods]?.rows.count == 1)
    assert(parsed?[.pods]?.rows.first?.cells["Name"] == "frontend-pod-1")
}

func testYAMLDiffCalculator() {
    let orig = """
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
  - port: 80
"""

    let modified = """
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
  - port: 8080
  - port: 443
"""

    let diff = YAMLDiffCalculator.diff(original: orig, modified: modified)
    assert(diff.hasChanges, "Diff must detect changes")
    assert(diff.additions == 2, "Expected 2 additions, got \(diff.additions)")
    assert(diff.deletions == 1, "Expected 1 deletion, got \(diff.deletions)")

    let identicalDiff = YAMLDiffCalculator.diff(original: orig, modified: orig)
    assert(!identicalDiff.hasChanges, "Identical content must have no changes")
    assert(identicalDiff.additions == 0 && identicalDiff.deletions == 0)
}

func testKubernetesYAMLApplier() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .success("service/web configured (dry run)")
    let applier = KubernetesYAMLApplier(kubectl: kubectl, timeout: 5)
    let context = testKubernetesContext()

    let sampleYAML = """
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
  - port: 80
"""

    // Dry Run
    let dryRunRes = await applier.dryRun(yaml: sampleYAML, context: context, namespace: "default")
    assert(dryRunRes.success, "Dry run must succeed")
    assert(dryRunRes.isDryRun, "Result must indicate isDryRun = true")
    assert(dryRunRes.stdout.contains("service/web configured (dry run)"))
    assert(kubectl.commands.count == 1)
    assert(kubectl.commands[0].arguments.contains("--dry-run=server"))
    assert(kubectl.commands[0].stdinData != nil)

    // Apply
    kubectl.defaultOutput = .success("service/web configured")
    let applyRes = await applier.apply(yaml: sampleYAML, context: context, namespace: "default")
    assert(applyRes.success, "Apply must succeed")
    assert(!applyRes.isDryRun, "Result must indicate isDryRun = false")
    assert(applyRes.appliedYAML == sampleYAML)
    assert(kubectl.commands.count == 2)
    assert(!kubectl.commands[1].arguments.contains("--dry-run=server"))
}

func testKubernetesWorkloadLifecycleService() async {
    let kubectl = ScriptedKubectl()
    let service = KubernetesWorkloadLifecycleService(kubectl: kubectl, timeout: 5)
    let context = testKubernetesContext()

    // Restart builds `rollout restart <kind>/<name>` scoped to the namespace.
    kubectl.defaultOutput = .success("deployment.apps/web restarted")
    let restartRes = await service.restart(kind: .deployment, name: "web", namespace: "prod", context: context)
    assert(restartRes.success, "Restart must succeed")
    assert(restartRes.message == "Restart triggered")
    let restartArgs = kubectl.commands.last!.arguments
    assert(restartArgs.contains("rollout"))
    assert(restartArgs.contains("restart"))
    assert(restartArgs.contains("deployment/web"))
    assert(restartArgs.contains("prod"), "Namespace must be passed through")

    // Scale to zero builds `scale <kind>/<name> --replicas=0`.
    kubectl.defaultOutput = .success("statefulset.apps/web scaled")
    let stopRes = await service.scale(kind: .statefulSet, name: "web", namespace: "prod", context: context, replicas: 0)
    assert(stopRes.success, "Scale to zero must succeed")
    assert(stopRes.message == "Stopped")
    let scaleArgs = kubectl.commands.last!.arguments
    assert(scaleArgs.contains("scale"))
    assert(scaleArgs.contains("statefulset/web"))
    assert(scaleArgs.contains("--replicas=0"))

    // Scaling back up reports the target count, not "Stopped".
    let startRes = await service.scale(kind: .statefulSet, name: "web", namespace: "prod", context: context, replicas: 3)
    assert(startRes.success)
    assert(startRes.message == "Scaled to 3")
    assert(kubectl.commands.last!.arguments.contains("--replicas=3"))

    // DaemonSets have no replica count — scale must be refused before ever
    // touching kubectl, not sent and left for the API server to reject.
    let commandCountBeforeDaemonSetScale = kubectl.commands.count
    let daemonScaleRes = await service.scale(kind: .daemonSet, name: "agent", namespace: "kube-system", context: context, replicas: 0)
    assert(!daemonScaleRes.success, "Scaling a DaemonSet must be refused")
    assert(kubectl.commands.count == commandCountBeforeDaemonSetScale, "Must not run kubectl for an unsupported scale")

    // Rollback builds `rollout undo <kind>/<name>`, including for DaemonSets
    // (which do support rollout history, unlike scale).
    kubectl.defaultOutput = .success("daemonset.apps/agent rolled back")
    let rollbackRes = await service.rollbackToPreviousRevision(kind: .daemonSet, name: "agent", namespace: "kube-system", context: context)
    assert(rollbackRes.success, "Rollback must succeed")
    let rollbackArgs = kubectl.commands.last!.arguments
    assert(rollbackArgs.contains("rollout"))
    assert(rollbackArgs.contains("undo"))
    assert(rollbackArgs.contains("daemonset/agent"))

    // A kubectl failure must surface its stderr, not report success.
    kubectl.defaultOutput = .failure(stderr: "Error from server (NotFound): deployments.apps \"web\" not found")
    let failedRes = await service.restart(kind: .deployment, name: "web", namespace: "prod", context: context)
    assert(!failedRes.success, "A non-zero exit code must be reported as failure")
    assert(failedRes.errorDetails?.contains("NotFound") == true)
}

func testKubernetesGitOpsOwnershipDetection() {
    let argoTrackingID = """
    {"metadata":{"name":"web","annotations":{"argocd.argoproj.io/tracking-id":"my-app:apps/Deployment:default/web"}}}
    """
    let argoOwnership = KubernetesWorkloadLifecycleService.parseGitOpsOwnership(fromObjectJSON: argoTrackingID)
    assert(argoOwnership?.controller == "ArgoCD")
    assert(argoOwnership?.applicationName == "my-app", "Must parse the app name out of the tracking-id, not the whole value")

    let argoInstanceLabel = """
    {"metadata":{"name":"web","labels":{"argocd.argoproj.io/instance":"my-app"}}}
    """
    let argoLabelOwnership = KubernetesWorkloadLifecycleService.parseGitOpsOwnership(fromObjectJSON: argoInstanceLabel)
    assert(argoLabelOwnership?.controller == "ArgoCD")
    assert(argoLabelOwnership?.applicationName == "my-app")

    let fluxKustomization = """
    {"metadata":{"name":"web","labels":{"kustomize.toolkit.fluxcd.io/name":"apps","kustomize.toolkit.fluxcd.io/namespace":"flux-system"}}}
    """
    let fluxOwnership = KubernetesWorkloadLifecycleService.parseGitOpsOwnership(fromObjectJSON: fluxKustomization)
    assert(fluxOwnership?.controller == "Flux")
    assert(fluxOwnership?.applicationName == "apps")

    let fluxHelmRelease = """
    {"metadata":{"name":"web","labels":{"helm.toolkit.fluxcd.io/name":"web-release"}}}
    """
    let fluxHelmOwnership = KubernetesWorkloadLifecycleService.parseGitOpsOwnership(fromObjectJSON: fluxHelmRelease)
    assert(fluxHelmOwnership?.controller == "Flux")
    assert(fluxHelmOwnership?.applicationName == "web-release")

    // A plain Helm release (or a hand-applied manifest with a conventional
    // label) must not be misreported as GitOps-managed — only tool-specific
    // markers count.
    let plainHelm = """
    {"metadata":{"name":"web","labels":{"app.kubernetes.io/instance":"web","app.kubernetes.io/managed-by":"Helm"}}}
    """
    assert(KubernetesWorkloadLifecycleService.parseGitOpsOwnership(fromObjectJSON: plainHelm) == nil)

    let unmanaged = """
    {"metadata":{"name":"web","labels":{}}}
    """
    assert(KubernetesWorkloadLifecycleService.parseGitOpsOwnership(fromObjectJSON: unmanaged) == nil)
}

func testKubernetesRolloutHistoryParsing() {
    let historyOutput = """
    deployment.apps/web
    REVISION  CHANGE-CAUSE
    1         <none>
    2         <none>
    3         kubectl set image deployment/web web=web:2.0
    """
    let revisions = KubernetesWorkloadLifecycleService.parseRolloutHistory(historyOutput)
    assert(revisions.map(\.revision) == [1, 2, 3])
    assert(revisions[0].changeCause == nil, "<none> must parse as no cause, not the literal string")
    assert(revisions[2].changeCause == "kubectl set image deployment/web web=web:2.0")

    let revisionDetail = """
    deployment.apps/web with revision #2
    Pod Template:
      Labels:\tapp=web
    \tpod-template-hash=abc123
      Containers:
       web:
        Image:\tweb:1.5
        Port:\t<none>
        Environment:\t<none>
        Mounts:\t<none>
      Volumes:\t<none>
    """
    assert(KubernetesWorkloadLifecycleService.parseImage(fromRevisionDetail: revisionDetail) == "web:1.5")

    let multiContainerDetail = """
    deployment.apps/web with revision #3
    Pod Template:
      Containers:
       web:
        Image:\tweb:2.0
       sidecar:\n        Image:\tenvoy:1.28
    """
    assert(KubernetesWorkloadLifecycleService.parseImage(fromRevisionDetail: multiContainerDetail) == "web:2.0, envoy:1.28")

    assert(KubernetesWorkloadLifecycleService.parseImage(fromRevisionDetail: "no image lines here") == nil)
}

func testKubernetesWorkloadLifecyclePreflight() async {
    let kubectl = ScriptedKubectl()
    let service = KubernetesWorkloadLifecycleService(kubectl: kubectl, timeout: 5)
    let context = testKubernetesContext()

    kubectl.outputForCommand = { command in
        let args = command.arguments
        if args.contains("--output=json") {
            return .success(#"{"metadata":{"annotations":{"argocd.argoproj.io/tracking-id":"my-app:apps/Deployment:default/web"}}}"#)
        }
        if args.contains("--revision=2") {
            return .success("deployment.apps/web with revision #2\nPod Template:\n  Containers:\n   web:\n    Image:\tweb:1.5")
        }
        if args.contains("--revision=3") {
            return .success("deployment.apps/web with revision #3\nPod Template:\n  Containers:\n   web:\n    Image:\tweb:2.0")
        }
        if args.contains("history") {
            return .success("deployment.apps/web\nREVISION  CHANGE-CAUSE\n2         <none>\n3         <none>")
        }
        return nil
    }

    let ownership = await service.detectGitOpsOwnership(kind: .deployment, name: "web", namespace: "prod", context: context)
    assert(ownership?.controller == "ArgoCD")
    assert(ownership?.applicationName == "my-app")
    assert(kubectl.commands.last?.arguments.contains("deployment/web") == true, "Must query the exact resource, not a list")

    let revisions = await service.recentRolloutRevisions(kind: .deployment, name: "web", namespace: "prod", context: context)
    assert(revisions.count == 2)
    assert(revisions.first(where: { $0.revision == 2 })?.image == "web:1.5")
    assert(revisions.first(where: { $0.revision == 3 })?.image == "web:2.0")
}

func runKubernetesWorkloadLifecycleTests() async {
    testKubernetesResourceParserBatchParsing()
    testYAMLDiffCalculator()
    await testKubernetesYAMLApplier()
    await testKubernetesWorkloadLifecycleService()
    testKubernetesGitOpsOwnershipDetection()
    testKubernetesRolloutHistoryParsing()
    await testKubernetesWorkloadLifecyclePreflight()
}
