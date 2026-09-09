import CTXCore
import Foundation

private func makeTempDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-backup-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func backups(in directory: URL, of filename: String) -> [URL] {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []
    return contents.filter { $0.lastPathComponent.hasPrefix("\(filename).ctx-backup-") }
}

func testSnapshotCopiesTheFileAndNamesItAfterTheOriginal() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let credentials = directory.appendingPathComponent("credentials")
    try! "[one]\nkey = value\n".write(to: credentials, atomically: true, encoding: .utf8)

    let backup = try! ConfigBackup.snapshot(credentials)
    // Named after the file it came from - a shared prefix would make a credentials
    // backup indistinguishable from a config backup in the same directory.
    assert(backup?.lastPathComponent.hasPrefix("credentials.ctx-backup-") == true)
    assert(try! String(contentsOf: backup!, encoding: .utf8) == "[one]\nkey = value\n")
    // The original is left exactly as it was.
    assert(try! String(contentsOf: credentials, encoding: .utf8) == "[one]\nkey = value\n")
}

func testSnapshotSkipsMissingFilesAndNeverCollides() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Nothing to preserve on a first write.
    let absent = directory.appendingPathComponent("not-there")
    assert(try! ConfigBackup.snapshot(absent) == nil)

    // Two snapshots in the same second must not overwrite each other.
    let config = directory.appendingPathComponent("config")
    try! "first".write(to: config, atomically: true, encoding: .utf8)
    let one = try! ConfigBackup.snapshot(config)
    try! "second".write(to: config, atomically: true, encoding: .utf8)
    let two = try! ConfigBackup.snapshot(config)

    assert(one != two)
    assert(try! String(contentsOf: one!, encoding: .utf8) == "first")
    assert(try! String(contentsOf: two!, encoding: .utf8) == "second")
    assert(backups(in: directory, of: "config").count == 2)
}

func testGCPWriterKeepsSettingsItHasNoFieldFor() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // A configuration gcloud wrote, carrying settings and a comment CTX never shows.
    let existing = """
    # kept by hand
    [core]
    project = old-project
    account = someone@example.com
    disable_prompts = true

    [compute]
    region = us-east1
    zone = us-east1-b

    [container]
    cluster = example-cluster
    """
    let target = directory.appendingPathComponent("config_example")
    try! existing.write(to: target, atomically: true, encoding: .utf8)

    var draft = GCPProfileDraft()
    draft.name = "example"
    draft.project = "new-project"
    draft.account = "someone@example.com"
    draft.region = "us-west1"
    try! GCPConfigWriter.writeConfig(draft, originalName: "example", dir: directory)

    let rewritten = try! String(contentsOf: target, encoding: .utf8)
    // The edited fields change...
    assert(rewritten.contains("project = new-project"))
    assert(rewritten.contains("region = us-west1"))
    assert(!rewritten.contains("project = old-project"))
    assert(!rewritten.contains("region = us-east1\n"))
    // ...and nothing else does.
    assert(rewritten.contains("# kept by hand"))
    assert(rewritten.contains("disable_prompts = true"))
    assert(rewritten.contains("zone = us-east1-b"))
    assert(rewritten.contains("[container]"))
    assert(rewritten.contains("cluster = example-cluster"))
    // A restore point still exists for the version before the edit.
    assert(backups(in: directory, of: "config_example").count == 1)
}

func testGCPWriterLeavesAnExistingRegionAloneWhenNoneIsGiven() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let target = directory.appendingPathComponent("config_example")
    try! "[core]\nproject = example-project\naccount = someone@example.com\n\n[compute]\nregion = us-east1\n"
        .write(to: target, atomically: true, encoding: .utf8)

    var draft = GCPProfileDraft()
    draft.name = "example"
    draft.project = "example-project"
    draft.account = "someone@example.com"
    draft.region = ""
    try! GCPConfigWriter.writeConfig(draft, originalName: "example", dir: directory)

    // An empty field means "not specified", never "erase what is there".
    assert(try! String(contentsOf: target, encoding: .utf8).contains("region = us-east1"))
}

func testGCPWriterPreservesOnRenameAndDelete() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let original = directory.appendingPathComponent("config_before")
    try! "[core]\nproject = example-project\naccount = someone@example.com\n"
        .write(to: original, atomically: true, encoding: .utf8)

    var draft = GCPProfileDraft()
    draft.name = "after"
    draft.project = "example-project"
    draft.account = "someone@example.com"
    try! GCPConfigWriter.writeConfig(draft, originalName: "before", dir: directory)

    assert(!FileManager.default.fileExists(atPath: original.path))
    assert(backups(in: directory, of: "config_before").count == 1)

    try! GCPConfigWriter.deleteConfig("after", dir: directory)
    assert(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("config_after").path))
    assert(backups(in: directory, of: "config_after").count == 1)
}

func testAzureWriterPreservesOnRewriteAndDelete() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // A profile carrying a key the Azure CLI wrote and CTX has no field for.
    let target = directory.appendingPathComponent("example.json")
    try! #"{"name":"example","subscriptionID":"00000000-0000-0000-0000-000000000000","extra":"kept"}"#
        .write(to: target, atomically: true, encoding: .utf8)

    var draft = AzureProfileDraft()
    draft.name = "example"
    draft.subscriptionID = "00000000-0000-0000-0000-000000000000"
    draft.tenantID = "11111111-1111-1111-1111-111111111111"
    draft.location = "westeurope"
    try! AzureConfigWriter.writeConfig(draft, originalName: "example", dir: directory)

    let rewritten = try! String(contentsOf: target, encoding: .utf8)
    // The key CTX has no field for survives the save...
    assert(rewritten.contains("kept"))
    // ...alongside the fields it does edit.
    assert(rewritten.contains("westeurope"))
    assert(rewritten.contains("11111111-1111-1111-1111-111111111111"))
    assert(backups(in: directory, of: "example.json").count == 1)

    try! AzureConfigWriter.deleteConfig("example", dir: directory)
    assert(!FileManager.default.fileExists(atPath: target.path))
    assert(backups(in: directory, of: "example.json").count == 2)
}

func testFirstWriteLeavesNoBackupBehind() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    var gcp = GCPProfileDraft()
    gcp.name = "fresh"
    gcp.project = "example-project"
    gcp.account = "someone@example.com"
    try! GCPConfigWriter.writeConfig(gcp, originalName: nil, dir: directory)

    var azure = AzureProfileDraft()
    azure.name = "fresh"
    azure.subscriptionID = "00000000-0000-0000-0000-000000000000"
    try! AzureConfigWriter.writeConfig(azure, originalName: nil, dir: directory)

    // Creating something new preserves nothing, so the directory stays clean.
    assert(backups(in: directory, of: "config_fresh").isEmpty)
    assert(backups(in: directory, of: "fresh.json").isEmpty)
}
