import CTXCore
import Foundation

let profiles = AWSConfigParser.parse("""
[profile it-admin]
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = eu-west-1

[sso-session jfrog]
sso_start_url = https://example.awsapps.com/start
""")

assert(profiles == [
    CloudProfile(
        provider: .aws,
        name: "it-admin",
        accountID: "123456789012",
        roleName: "AdministratorAccess",
        region: "eu-west-1"
    )
])

let linkedProfiles = AWSConfigParser.parse("""
[sso-session corp]
sso_start_url = https://corp.awsapps.com/start
sso_region = eu-west-1

[profile corp-admin]
sso_session = corp
sso_account_id = 123456789012
sso_role_name = Admin
region = eu-west-1
""")

assert(linkedProfiles.first?.ssoStartURL == "https://corp.awsapps.com/start")
assert(linkedProfiles.first?.ssoRegion == "eu-west-1")
assert(CloudFolder.builtIn(provider: .aws, environment: .production).icon == .server)
assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "seller-prod")) == .production)

var draft = AWSProfileDraft()
draft.name = "demo"
draft.ssoStartURL = "https://example.awsapps.com/start"
draft.ssoRegion = "eu-west-1"
draft.accountID = "123456789012"
draft.roleName = "AdministratorAccess"
draft.defaultRegion = "eu-west-1"

let temporaryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ctx-check-\(UUID().uuidString)")
    .appendingPathComponent("config")

try AWSConfigWriter.appendProfile(draft, to: temporaryURL)
let written = try String(contentsOf: temporaryURL, encoding: .utf8)
assert(written.contains("[profile demo]"))
assert(written.contains("sso_account_id = 123456789012"))

draft.roleName = "PowerUserAccess"
try AWSConfigWriter.updateProfile(originalName: "demo", draft: draft, to: temporaryURL)
let edited = try String(contentsOf: temporaryURL, encoding: .utf8)
assert(edited.contains("sso_role_name = PowerUserAccess"))
assert(!edited.contains("sso_role_name = AdministratorAccess"))

try AWSConfigWriter.deleteProfile("demo", from: temporaryURL)
let deleted = try String(contentsOf: temporaryURL, encoding: .utf8)
assert(!deleted.contains("[profile demo]"))
assert(!deleted.contains("[sso-session demo]"))

draft.roleName = "Admin\noutput = text"
do {
    try AWSConfigWriter.appendProfile(draft, to: temporaryURL)
    assertionFailure("Expected newline injection to fail")
} catch AWSConfigWriterError.invalid("role name") {
}

// Test GCP Config Parser
let tempGCPConfigDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ctx-check-gcp-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempGCPConfigDir, withIntermediateDirectories: true)
let tempGCPConfigURL = tempGCPConfigDir.appendingPathComponent("config_default")
let gcpConfigContent = """
[core]
account = eliasafa@jfrog.com
project = support-prod-157422

[compute]
region = us-central1
"""
try gcpConfigContent.write(to: tempGCPConfigURL, atomically: true, encoding: .utf8)

let gcpProfile = GCPConfigParser.parse(contentsOf: tempGCPConfigURL, name: "default")
assert(gcpProfile != nil)
assert(gcpProfile?.provider == .gcp)
assert(gcpProfile?.name == "default")
assert(gcpProfile?.accountID == "support-prod-157422")
assert(gcpProfile?.roleName == "eliasafa@jfrog.com")
assert(gcpProfile?.region == "us-central1")
assert(CloudFolder.builtIn(provider: .gcp, environment: .production).icon == .server)
assert(CloudEnvironment.infer(from: gcpProfile!) == .production)

// Test GCP Config Writer
var gcpDraft = GCPProfileDraft()
gcpDraft.name = "prod"
gcpDraft.project = "prod-project"
gcpDraft.account = "prod-user@example.com"
gcpDraft.region = "us-east1"

try GCPConfigWriter.writeConfig(gcpDraft, originalName: nil, dir: tempGCPConfigDir)
let parsedGCP = GCPConfigParser.parse(contentsOf: tempGCPConfigDir.appendingPathComponent("config_prod"), name: "prod")
assert(parsedGCP != nil)
assert(parsedGCP?.name == "prod")
assert(parsedGCP?.accountID == "prod-project")
assert(parsedGCP?.roleName == "prod-user@example.com")
assert(parsedGCP?.region == "us-east1")

// Edit
gcpDraft.region = "us-west2"
try GCPConfigWriter.writeConfig(gcpDraft, originalName: "prod", dir: tempGCPConfigDir)
let editedGCP = GCPConfigParser.parse(contentsOf: tempGCPConfigDir.appendingPathComponent("config_prod"), name: "prod")
assert(editedGCP?.region == "us-west2")

// Delete
try GCPConfigWriter.deleteConfig("prod", dir: tempGCPConfigDir)
assert(!FileManager.default.fileExists(atPath: tempGCPConfigDir.appendingPathComponent("config_prod").path))

// Clean up
try? FileManager.default.removeItem(at: tempGCPConfigDir)

print("CTX checks passed")

