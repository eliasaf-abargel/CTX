import CTXCore
import Foundation

func testIndentedKubeDiscoveryPreservesEntriesAndUsers() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    // Both common serializers: unindented/indented lists, name before/after body.
    for padding in ["", "  ", "    "] {
        let sections = [
            "clusters:",
            "- cluster:\n    server: https://127.0.0.1:6443\n  name: broker-cluster\n- name: cloud-cluster\n  cluster:\n    server: https://example.com",
            "contexts:",
            "- context:\n    cluster: broker-cluster\n    user: sdm-broker\n  name: team-eks\n- name: cloud-context\n  context:\n    cluster: cloud-cluster\n    user: cloud-user",
            "users:",
            "- name: sdm-broker\n  user:\n    token: synthetic-test-value\n- user:\n    exec:\n      command: aws\n      env:\n      - name: AWS_PROFILE\n        value: team\n  name: cloud-user"
        ]
        let text = sections.enumerated().map { index, value in
            index.isMultiple(of: 2) ? value : value.split(separator: "\n").map { padding + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let result = KubeConfigDiscoveryService().discover(paths: [path])
        assert(result.contexts.count == 2)
        let broker = result.contexts.first { $0.contextName == "team-eks" }!
        assert(broker.userName == "sdm-broker")
        assert(broker.clusterMetadata.serverURL == "https://127.0.0.1:6443")
        assert(KubernetesProfileAdapter.cloudProfile(from: broker).usesStrongDM)
        let cloud = result.contexts.first { $0.contextName == "cloud-context" }!
        assert(cloud.credentialKind == .execPlugin && cloud.hasCredentials)
        assert(cloud.userName == "cloud-user")
    }
}

func testExplicitKubeAWSProfileDoesNotUseGlobalSelection() throws {
    func config(_ plugin: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["users": [["user": ["exec": plugin]]]])
    }
    let unlinked = try config(["command": "aws"])
    assert(ProfileCommandService.explicitAWSProfile(in: unlinked) == nil)
    let linked = try config(["command": "aws", "env": [["name": "AWS_PROFILE", "value": "team"]]])
    assert(ProfileCommandService.explicitAWSProfile(in: linked) == "team")
    let broker = try config(["command": "sdm", "env": [["name": "AWS_PROFILE", "value": "team"]]])
    assert(ProfileCommandService.explicitAWSProfile(in: broker) == nil)
    let explicit = try config(["command": "aws", "args": ["--profile", "other"], "env": [["name": "AWS_PROFILE", "value": "team"]]])
    assert(ProfileCommandService.explicitAWSProfile(in: explicit) == "other")
}

func testLocalDiagnosticsAreBoundedAndExcludeIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LocalDiagnostics(directory: directory, maximumBytes: 400)
    for _ in 0..<10 {
        try log.record(step: "test", contextID: "private-context-sentinel", outcome: "error")
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    assert(files.count == 2)
    for file in files {
        let data = try Data(contentsOf: file)
        assert(data.count <= 400)
        assert(!String(decoding: data, as: UTF8.self).contains("private-context-sentinel"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        assert(permissions.intValue == 0o600)
    }
}

@MainActor
func testDiscoveryRetainsContextsDuringFileReplacement() throws {
    let (store, directory, defaults, suite) = try makeLifecycleStore(profileNames: [], runner: LifecycleGateRunner())
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let path = directory.appendingPathComponent("missing-kubeconfig")
    let text = kubeconfig(context: "team", cluster: "team", user: "broker", server: "https://example.com")
    try text.write(to: path, atomically: true, encoding: .utf8)
    store.refreshImmediately(runVerification: false)
    assert(store.kubernetesContexts.count == 1)
    try FileManager.default.removeItem(at: path)
    store.refreshImmediately(runVerification: false)
    assert(store.kubernetesContexts.count == 1)
    assert(store.profiles.first { $0.provider == .kubernetes }?.status == .unknown)
    try "".write(to: path, atomically: true, encoding: .utf8)
    store.refreshImmediately(runVerification: false)
    assert(store.kubernetesContexts.count == 1)
    try text.replacingOccurrences(of: "team", with: "other").write(to: path, atomically: true, encoding: .utf8)
    store.refreshImmediately(runVerification: false)
    assert(store.kubernetesContexts.map(\.contextName) == ["other"])
}
