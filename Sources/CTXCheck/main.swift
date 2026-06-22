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

print("CTX checks passed")
