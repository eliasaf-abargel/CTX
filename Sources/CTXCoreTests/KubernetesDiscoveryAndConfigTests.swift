import Foundation
@testable import CTXCore

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

func testKubernetesBearerTokensNeverEnterSharedProfileState() throws {
    let sentinel = "CTX_SENTINEL_BEARER_SECRET_7f34"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-secret-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let path = dir.appendingPathComponent("config")
    try """
    apiVersion: v1
    clusters:
    - name: secure-cluster
      cluster:
        server: https://secure.example.com
    contexts:
    - name: secure-context
      context:
        cluster: secure-cluster
        user: secure-user
    current-context: secure-context
    users:
    - name: secure-user
      user:
        token: \(sentinel)
    """.write(to: path, atomically: true, encoding: .utf8)

    let result = KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
        .discover(paths: [path])
    guard let context = result.contexts.first else {
        assertionFailure("expected the secure context to be discovered")
        return
    }
    assert(context.credentialKind == .bearerToken)
    assert(context.hasCredentials)
    assert(!String(reflecting: context).contains(sentinel))

    let cloudProfile = KubernetesProfileAdapter.cloudProfile(from: context)
    assert(cloudProfile.kubernetesCredentialKind == .bearerToken)
    assert(cloudProfile.hasKubernetesCredentials)
    assert(!String(reflecting: cloudProfile).contains(sentinel))

    let contextJSON = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    let cloudJSON = String(decoding: try JSONEncoder().encode(cloudProfile), as: UTF8.self)
    assert(!contextJSON.contains(sentinel))
    assert(!cloudJSON.contains(sentinel))
    assert(!contextJSON.contains("\"token\""))
    assert(!cloudJSON.contains("\"token\""))

    let legacyCloudJSON = """
    {"provider":"Kubernetes","name":"legacy-context","token":"\(sentinel)"}
    """
    let decodedLegacy = try JSONDecoder().decode(CloudProfile.self, from: Data(legacyCloudJSON.utf8))
    let reencodedLegacy = String(decoding: try JSONEncoder().encode(decodedLegacy), as: UTF8.self)
    assert(decodedLegacy.kubernetesCredentialKind == .bearerToken)
    assert(decodedLegacy.hasKubernetesCredentials)
    assert(!String(reflecting: decodedLegacy).contains(sentinel))
    assert(!reencodedLegacy.contains(sentinel))
    assert(!reencodedLegacy.contains("\"token\""))
}

func testKubeConfigDiscoveryHandlesNameAfterNestedClusterOrContextKey() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-name-after-nested-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

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

func testKubeConfigDiscoveryParsesLinkedAWSProfile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-linked-aws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let path = dir.appendingPathComponent("config")
    try """
    apiVersion: v1
    clusters:
    - name: eks-cluster
      cluster:
        server: https://eks.example.com
    contexts:
    - name: eks-context
      context:
        cluster: eks-cluster
        user: eks-user
    current-context: eks-context
    users:
    - name: eks-user
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1beta1
          command: aws
          args:
          - eks
          - get-token
          - --cluster-name
          - prod-eks
          - --profile
          - stg-is
    """.write(to: path, atomically: true, encoding: .utf8)

    let result = KubeConfigDiscoveryService(environment: { [:] }, customPath: { nil })
        .discover(paths: [path])
    guard let context = result.contexts.first else {
        assertionFailure("expected the context to be discovered")
        return
    }
    assert(context.linkedAWSProfile == "stg-is")
    let cloudProfile = KubernetesProfileAdapter.cloudProfile(from: context)
    assert(cloudProfile.kubernetesLinkedProfile == "stg-is")
}

func testKubeConfigMutationServiceAddsContextWithDefaults() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.addContext(name: "dev", server: "https://127.0.0.1:6443", cluster: "", user: "", namespace: "apps", credential: .bearerToken("demo-token"))

    let commands = kubectl.commands.map(\.arguments)
    assert(commands == [
        ["config", "set-cluster", "dev-cluster", "--server=https://127.0.0.1:6443", "--insecure-skip-tls-verify=false"],
        ["config", "set-credentials", "dev-user", "--token=demo-token"],
        ["config", "set-context", "dev", "--cluster=dev-cluster", "--user=dev-user", "--namespace=apps"]
    ])
}

func testKubeConfigMutationServiceRequiresExplicitInsecureTLS() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.addContext(
        name: "self-signed",
        server: "https://cluster.example.com",
        cluster: "self-signed-cluster",
        user: "",
        namespace: "",
        credential: .bearerToken(nil),
        skipTLSVerification: true
    )

    assert(kubectl.commands.first?.arguments.contains("--insecure-skip-tls-verify=true") == true)
}

func testKubeConfigMutationServiceNamespaceEditPreservesTLSPolicy() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.updateContext(
        oldName: "secure",
        newName: "secure",
        server: "https://cluster.example.com",
        cluster: "secure-cluster",
        user: "secure-user",
        namespace: "new-namespace",
        credentialUpdate: .preserveExisting
    )

    let clusterCommand = kubectl.commands.first { $0.arguments.contains("set-cluster") }
    assert(clusterCommand != nil)
    assert(clusterCommand?.arguments.contains(where: { $0.hasPrefix("--insecure-skip-tls-verify") }) == false)
}

func testKubeConfigMutationServiceTargetsGivenKubeconfigPath() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.addContext(
        name: "dev",
        server: "https://127.0.0.1:6443",
        cluster: "",
        user: "",
        namespace: "apps",
        credential: .bearerToken("demo-token"),
        kubeconfigPath: "/tmp/custom-kubeconfig"
    )

    assert(kubectl.commands.allSatisfy {
        Array($0.arguments.prefix(2)) == ["--kubeconfig", "/tmp/custom-kubeconfig"]
            && $0.environmentOverrides["KUBECONFIG"] == "/tmp/custom-kubeconfig"
    }, "every kubectl call must be scoped to the caller's kubeconfig path")
}

func testKubeConfigMutationServiceDuplicatesOnlyTheContextRecord() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.duplicateContext(
        sourceName: " source ",
        newName: " source-copy ",
        cluster: "shared-cluster",
        user: "shared-user",
        namespace: "apps",
        kubeconfigPath: "/tmp/team-kubeconfig"
    )

    let commands = kubectl.commands.map(\.arguments)
    assert(commands == [[
        "--kubeconfig", "/tmp/team-kubeconfig",
        "config", "set-context", "source-copy",
        "--cluster=shared-cluster",
        "--user=shared-user",
        "--namespace=apps"
    ]])
    let forbiddenMutations = ["rename-context", "set-cluster", "set-credentials", "delete-context", "unset"]
    assert(commands.flatMap { $0 }.allSatisfy { !forbiddenMutations.contains($0) })
}

func testKubeConfigMutationServiceAddsEKSExecCredential() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.addContext(
        name: "example-eks",
        server: "https://example.us-east-1.eks.amazonaws.com",
        cluster: "example-eks",
        user: "",
        namespace: "default",
        credential: .awsEKS(region: "us-east-1", profile: "ops-admin")
    )

    let commands = kubectl.commands.map(\.arguments)
    assert(commands == [
        ["config", "set-cluster", "example-eks", "--server=https://example.us-east-1.eks.amazonaws.com", "--insecure-skip-tls-verify=false"],
        [
            "config", "set-credentials", "example-eks-user",
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
        ["config", "set-context", "example-eks", "--cluster=example-eks", "--user=example-eks-user", "--namespace=default"]
    ])
}

func testKubeConfigMutationServiceAddsInternalProxyWithoutUser() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.addContext(
        name: "internal-prod",
        server: "https://127.0.0.1:8443",
        cluster: "internal-prod",
        user: "",
        namespace: "default",
        credential: .internalProxy
    )

    let commands = kubectl.commands.map(\.arguments)
    assert(commands == [
        ["config", "set-cluster", "internal-prod", "--server=https://127.0.0.1:8443", "--insecure-skip-tls-verify=false"],
        ["config", "set-context", "internal-prod", "--cluster=internal-prod", "--namespace=default"]
    ])
}

func testKubeConfigMutationServiceUpdateClearsNamespaceWhenEmpty() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.updateContext(oldName: "old", newName: "new", server: "http://127.0.0.1:8080", cluster: "cluster-a", user: "user-a", namespace: "", credentialUpdate: .preserveExisting)

    let commands = kubectl.commands.map(\.arguments)
    assert(commands == [
        ["config", "rename-context", "old", "new"],
        ["config", "set-cluster", "cluster-a", "--server=http://127.0.0.1:8080"],
        ["config", "set-context", "new", "--cluster=cluster-a", "--user=user-a", "--namespace="]
    ])
}

func testKubeConfigMutationServicePreservesCredentialsUnlessExplicitlyReplaced() async throws {
    let sentinel = "CTX_SENTINEL_REPLACEMENT_TOKEN_91c2"
    let preservingKubectl = ScriptedKubectl()
    let preservingService = KubeConfigMutationService(kubectl: preservingKubectl)

    try await preservingService.updateContext(
        oldName: "secure",
        newName: "secure",
        server: "https://secure.example.com",
        cluster: "secure-cluster",
        user: "secure-user",
        namespace: "apps",
        credentialUpdate: .preserveExisting
    )

    assert(!preservingKubectl.commands.contains { $0.arguments.contains("set-credentials") })
    assert(!preservingKubectl.commands.contains { $0.arguments.contains("unset") })
    assert(!preservingKubectl.commands.description.contains(sentinel))

    let replacingKubectl = ScriptedKubectl()
    let replacingService = KubeConfigMutationService(kubectl: replacingKubectl)
    try await replacingService.updateContext(
        oldName: "secure",
        newName: "secure",
        server: "https://secure.example.com",
        cluster: "secure-cluster",
        user: "secure-user",
        namespace: "apps",
        credentialUpdate: .replace(.bearerToken(sentinel))
    )

    let credentialCommands = replacingKubectl.commands.filter { $0.arguments.contains("set-credentials") }
    assert(credentialCommands.count == 1)
    assert(credentialCommands[0].arguments == [
        "config", "set-credentials", "secure-user", "--token=\(sentinel)"
    ])
}

func testKubeContextEditorAllowsAddingATokenWhenThereIsNoCredential() {
    assert(KubeContextBearerTokenIntent.showsTokenField(hasExistingCredential: false, isReplacementRequested: false))
    assert(!KubeContextBearerTokenIntent.showsTokenField(hasExistingCredential: true, isReplacementRequested: false))
    assert(KubeContextBearerTokenIntent.showsTokenField(hasExistingCredential: true, isReplacementRequested: true))

    let sentinel = "CTX_SENTINEL_EDITOR_TOKEN_4f7a"
    assert(KubeContextBearerTokenIntent.credentialUpdate(
        hasExistingCredential: false,
        isReplacementRequested: false,
        token: "  \(sentinel)  "
    ) == .replace(.bearerToken(sentinel)))

    assert(KubeContextBearerTokenIntent.credentialUpdate(
        hasExistingCredential: false,
        isReplacementRequested: false,
        token: "   "
    ) == .preserveExisting)
    assert(KubeContextBearerTokenIntent.credentialUpdate(
        hasExistingCredential: true,
        isReplacementRequested: true,
        token: ""
    ) == .preserveExisting)

    assert(KubeContextBearerTokenIntent.credentialUpdate(
        hasExistingCredential: true,
        isReplacementRequested: true,
        token: sentinel
    ) == .replace(.bearerToken(sentinel)))

    assert(KubeContextBearerTokenIntent.credentialUpdate(
        hasExistingCredential: true,
        isReplacementRequested: false,
        token: sentinel
    ) == .preserveExisting)
}

func testKubeConfigMutationServiceReplacesCredentialsWithoutErasingFirst() async throws {
    let sentinel = "CTX_SENTINEL_REPLACEMENT_TOKEN_91c2"
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        command.arguments.contains("view")
            ? .success(#"{"users":[{"name":"shared-user","user":{"exec":{"command":"aws"}}}]}"#)
            : nil
    }
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.updateContext(
        oldName: "secure",
        newName: "secure",
        server: "https://secure.example.com",
        cluster: "secure-cluster",
        user: "shared-user",
        namespace: "apps",
        credentialUpdate: .replace(.bearerToken(sentinel))
    )

    let commands = kubectl.commands.map(\.arguments)
    assert(!commands.contains(["config", "unset", "users.shared-user"]), "the user entry must never be deleted wholesale")

    guard let writeIndex = commands.firstIndex(where: { $0.contains("set-credentials") }),
          let contextIndex = commands.firstIndex(where: { $0.contains("set-context") }),
          let cleanupIndex = commands.firstIndex(where: { $0.contains("unset") })
    else {
        assertionFailure("expected a write, a context update and a cleanup, got \(commands)")
        return
    }
    assert(commands[writeIndex] == ["config", "set-credentials", "shared-user", "--token=\(sentinel)"])
    assert(commands[cleanupIndex] == ["config", "unset", "users.shared-user.exec"])
    assert(writeIndex < cleanupIndex, "the stale field was cleared before the replacement was on disk")
    assert(contextIndex < cleanupIndex, "cleanup must be last, so failing it cannot half-apply the edit")

    let cleanKubectl = ScriptedKubectl()
    cleanKubectl.outputForCommand = { command in
        command.arguments.contains("view") ? .success("") : nil
    }
    try await KubeConfigMutationService(kubectl: cleanKubectl).updateContext(
        oldName: "secure",
        newName: "secure",
        server: "https://secure.example.com",
        cluster: "secure-cluster",
        user: "shared-user",
        namespace: "apps",
        credentialUpdate: .replace(.bearerToken(sentinel))
    )
    assert(!cleanKubectl.commands.contains { $0.arguments.contains("unset") })
}

func testKubeConfigMutationServiceKeepsCredentialsWhenTheReplacementWriteFails() async {
    let sentinel = "CTX_SENTINEL_REPLACEMENT_TOKEN_91c2"
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        command.arguments.contains("set-credentials") ? .failure(stderr: "forbidden") : nil
    }
    let service = KubeConfigMutationService(kubectl: kubectl)

    do {
        try await service.updateContext(
            oldName: "secure",
            newName: "secure",
            server: "https://secure.example.com",
            cluster: "secure-cluster",
            user: "shared-user",
            namespace: "apps",
            credentialUpdate: .replace(.bearerToken(sentinel))
        )
        assertionFailure("expected the failed credential write to surface")
    } catch {
        assert(error.localizedDescription.contains("Failed to update credentials"))
        assert(!error.localizedDescription.contains(sentinel))
    }

    let commands = kubectl.commands.map(\.arguments)
    assert(!commands.contains { $0.contains("unset") }, "a failed replacement must leave the existing credential in place")
    assert(commands.filter { $0.contains("set-credentials") }.count == 1)
}

func testKubeConfigMutationServiceReplacesEKSCredentialInASingleWrite() async throws {
    let kubectl = ScriptedKubectl()
    let service = KubeConfigMutationService(kubectl: kubectl)

    try await service.updateContext(
        oldName: "example-eks",
        newName: "example-eks",
        server: "https://example.us-east-1.eks.amazonaws.com",
        cluster: "example-eks",
        user: "example-eks-user",
        namespace: "default",
        credentialUpdate: .replace(.awsEKS(region: "us-east-1", profile: "ops-admin"))
    )

    let credentialCommands = kubectl.commands.map(\.arguments).filter { $0.contains("set-credentials") }
    assert(credentialCommands.count == 1)
    assert(credentialCommands[0] == [
        "config", "set-credentials", "example-eks-user",
        "--token=",
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
    ])
    assert(!kubectl.commands.contains { $0.arguments.contains("unset") })
}

func testKubeConfigMutationServiceReportsAStaleFieldItCouldNotClear() async {
    let sentinel = "CTX_SENTINEL_REPLACEMENT_TOKEN_91c2"
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        if command.arguments.contains("view") {
            return .success(#"{"users":[{"name":"shared-user","user":{"exec":{"command":"aws"}}}]}"#)
        }
        if command.arguments.contains("unset") { return .failure(stderr: "kubeconfig is read-only") }
        return nil
    }
    let service = KubeConfigMutationService(kubectl: kubectl)

    do {
        try await service.updateContext(
            oldName: "secure",
            newName: "secure",
            server: "https://secure.example.com",
            cluster: "secure-cluster",
            user: "shared-user",
            namespace: "apps",
            credentialUpdate: .replace(.bearerToken(sentinel))
        )
        assertionFailure("expected the failed cleanup to be reported")
    } catch let error as KubeConfigMutationError {
        guard case .staleCredentialField(let message) = error else {
            assertionFailure("expected a stale-field error, got \(error)")
            return
        }
        assert(message.contains("saved"))
        assert(!message.contains(sentinel))
    } catch {
        assertionFailure("expected a KubeConfigMutationError, got \(error)")
    }

    assert(kubectl.commands.map(\.arguments).contains([
        "config", "set-credentials", "shared-user", "--token=\(sentinel)"
    ]), "the replacement itself must still have been written")
}

func testKubeConfigMutationServiceUsesExactNamesForJSONLookupsAndEscapedUnset() async throws {
    let clusterName = #"prod.cluster"west"#
    let userName = "team.user"
    let configJSON = #"""
    {
      "clusters": [
        {"name":"prod.cluster","cluster":{"server":"https://wrong.example.com"}},
        {"name":"prod.cluster\"west","cluster":{"server":"https://right.example.com"}}
      ],
      "users": [
        {"name":"team","user":{"exec":{"command":"wrong"}}},
        {"name":"team.user","user":{"exec":{"command":"aws"}}}
      ]
    }
    """#
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        command.arguments.contains("view") ? .success(configJSON) : nil
    }
    let service = KubeConfigMutationService(kubectl: kubectl)

    let server = await service.resolveServer(for: clusterName)
    try await service.updateContext(
        oldName: "edge",
        newName: "edge",
        server: server,
        cluster: clusterName,
        user: userName,
        namespace: "",
        credentialUpdate: .replace(.bearerToken("replacement"))
    )

    assert(server == "https://right.example.com")
    assert(kubectl.commands.contains {
        $0.arguments == ["config", "unset", #"users.team\.user.exec"#]
    })
    assert(!kubectl.commands.contains {
        $0.arguments == ["config", "unset", "users.team.exec"]
    })
}

func testKubeConfigMutationServiceRedactsSensitiveFailureOutput() async {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .failure(stderr: "bearer demo-token failed")
    let service = KubeConfigMutationService(kubectl: kubectl)

    do {
        try await service.deleteContext("prod")
        assertionFailure("Expected delete failure")
    } catch {
        let message = error.localizedDescription
        assert(message.contains("[redacted]"))
        assert(!message.contains("demo-token"))
    }
}

func testKubeConfigMutationServiceUnsetsCurrentContextOnDelete() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        if command.arguments.contains("current-context") && !command.arguments.contains("unset") {
            return .success("active-ctx\n")
        }
        return .success("")
    }
    let service = KubeConfigMutationService(kubectl: kubectl)
    try await service.deleteContext("active-ctx")

    let commands = kubectl.commands.map(\.arguments)
    assert(commands.contains(["config", "current-context"]))
    assert(commands.contains(["config", "delete-context", "active-ctx"]))
    assert(commands.contains(["config", "unset", "current-context"]))
}

func testKubeConfigMutationServiceDoesNotUnsetWhenInactiveContextDeleted() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        if command.arguments.contains("current-context") && !command.arguments.contains("unset") {
            return .success("other-ctx\n")
        }
        return .success("")
    }
    let service = KubeConfigMutationService(kubectl: kubectl)
    try await service.deleteContext("inactive-ctx")

    let commands = kubectl.commands.map(\.arguments)
    assert(commands.contains(["config", "current-context"]))
    assert(commands.contains(["config", "delete-context", "inactive-ctx"]))
    assert(!commands.contains(["config", "unset", "current-context"]))
}

func runKubernetesDiscoveryAndConfigTests() async throws {
    try testKubeConfigDiscoverySingleFile()
    try testKubernetesBearerTokensNeverEnterSharedProfileState()
    try testKubeConfigDiscoveryHandlesNameAfterNestedClusterOrContextKey()
    try testKubeConfigDiscoveryUsesKubeconfigMultipath()
    try testKubeConfigDiscoveryCustomPathOverridesKubeconfig()
    try testKubeConfigDiscoveryDeduplicatesContextNames()
    try testKubeConfigDiscoveryHandlesInvalidFiles()
    try testKubeConfigDiscoveryParsesLinkedAWSProfile()
    try testLocalProfileDiscoveryLoadsAWSAndKubernetesProfiles()
    try await testKubeConfigMutationServiceAddsContextWithDefaults()
    try await testKubeConfigMutationServiceRequiresExplicitInsecureTLS()
    try await testKubeConfigMutationServiceNamespaceEditPreservesTLSPolicy()
    try await testKubeConfigMutationServiceTargetsGivenKubeconfigPath()
    try await testKubeConfigMutationServiceDuplicatesOnlyTheContextRecord()
    try await testKubeConfigMutationServiceAddsEKSExecCredential()
    try await testKubeConfigMutationServiceAddsInternalProxyWithoutUser()
    try await testKubeConfigMutationServiceUpdateClearsNamespaceWhenEmpty()
    try await testKubeConfigMutationServicePreservesCredentialsUnlessExplicitlyReplaced()
    testKubeContextEditorAllowsAddingATokenWhenThereIsNoCredential()
    try await testKubeConfigMutationServiceReplacesCredentialsWithoutErasingFirst()
    await testKubeConfigMutationServiceKeepsCredentialsWhenTheReplacementWriteFails()
    try await testKubeConfigMutationServiceReplacesEKSCredentialInASingleWrite()
    await testKubeConfigMutationServiceReportsAStaleFieldItCouldNotClear()
    try await testKubeConfigMutationServiceUsesExactNamesForJSONLookupsAndEscapedUnset()
    await testKubeConfigMutationServiceRedactsSensitiveFailureOutput()
    try await testKubeConfigMutationServiceUnsetsCurrentContextOnDelete()
    try await testKubeConfigMutationServiceDoesNotUnsetWhenInactiveContextDeleted()
}
