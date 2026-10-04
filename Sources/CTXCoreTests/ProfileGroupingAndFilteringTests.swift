import CTXCore
import Foundation

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

    store.requestFolderDeletion(payments, from: .settings)
    assert(store.allFolders.contains { $0.id == payments.id }, "requesting deletion must not mutate folders")
    guard let deletion = store.presentation else {
        assertionFailure("folder deletion must publish a confirmation route")
        return
    }
    store.consumePresentation(id: deletion.id, from: .mainWindow)
    assert(store.presentation?.id == deletion.id, "a non-originating surface must not consume the route")
    store.confirmFolderDeletion(payments, from: .mainWindow)
    assert(store.allFolders.contains { $0.id == payments.id }, "a non-originating surface must not confirm deletion")
    assert(store.presentation?.id == deletion.id, "wrong-origin confirmation must preserve the request")
    store.confirmFolderDeletion(payments, from: .settings)
    assert(!store.allFolders.contains { $0.id == payments.id })
    assert(grouped("Production") == ["shop-prod"], "profile must fall back to its inferred folder: \(grouped("Production"))")

    // Hiding a built-in folder removes it from both views.
    let production = store.allFolders.first { $0.provider == .aws && $0.name == "Production" }!
    store.requestFolderDeletion(production, from: .mainWindow)
    store.confirmFolderDeletion(production, from: .mainWindow)
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
    // Multi-token search across columns.
    assert(KubernetesResourceRow.filtered(rows, matching: "team-a crashloop").count == 1)
    assert(KubernetesResourceRow.filtered(rows, matching: "team-a zzz").isEmpty)
    // Negative token exclusion.
    assert(KubernetesResourceRow.filtered(rows, matching: "team -web").map(\.id) == ["team-a/api-7d9f"])
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

    // Everything the store reads or writes is scoped to this temporary directory
    // and to `defaults`: the developer's own kubeconfig, gcloud and Azure state —
    // and their remembered active profiles — must survive a test run untouched.
    let kubeConfigDiscoveryService = KubeConfigDiscoveryService(
        environment: { [:] },
        customPath: { dir.appendingPathComponent("missing-kubeconfig").path }
    )
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: kubeConfigDiscoveryService,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: configURL,
            kubeConfigDiscoveryService: kubeConfigDiscoveryService,
            gcpConfigurationsDirURL: { dir.appendingPathComponent("missing-gcloud") },
            gcpActiveConfigURL: { dir.appendingPathComponent("missing-gcloud/active_config") },
            azureProfilesDirURL: { dir.appendingPathComponent("missing-azure") }
        ),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("creds")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        defaults: defaults,
        startsBackgroundServices: false
    )

    // Let the first pass settle: rediscovery *plus* the verification behind it,
    // whose status transitions are real changes and must publish.
    store.refresh()
    try await Task.sleep(nanoseconds: 900_000_000)

    var publishCount = 0
    var publications: [[String]] = []
    let cancellable = store.$profiles.dropFirst().sink { profiles in
        publishCount += 1
        publications.append(profiles.map { "\($0.id)=\($0.status.rawValue)" })
    }
    defer { cancellable.cancel() }

    // Second pass: nothing on disk changed and verification returns what it
    // returned last time, so the whole cycle must be a no-op.
    store.refresh()
    try await Task.sleep(nanoseconds: 900_000_000)
    assert(publishCount == 0, "an unchanged rediscovery republished \(publishCount) times: \(publications)")

    // A real change still comes through.
    try "[profile shop-prod]\nsso_account_id = 123456789012\n\n[profile shop-dev]\nsso_account_id = 210987654321\n"
        .write(to: configURL, atomically: true, encoding: .utf8)
    store.refresh()
    try await Task.sleep(nanoseconds: 900_000_000)
    assert(publishCount >= 1, "a real change must republish")
    let discovered = store.profiles.filter { $0.name.hasPrefix("shop-") }.map(\.name).sorted()
    assert(discovered == ["shop-dev", "shop-prod"], "got \(discovered)")
}



@MainActor
func runProfileGroupingAndFilteringTests() async throws {
    try testGroupedProfilesStayInSyncWithEveryMutation()
    try testCrossProviderOverrideFallsBackInsteadOfHidingTheProfile()
    try testCredentialExpiriesParseEveryProfileInOnePass()
    try testRowFilteringSurvivesEncodingAndMatchesTheOldSemantics()
    try await testUnchangedRediscoveryDoesNotRepublishProfiles()
}
