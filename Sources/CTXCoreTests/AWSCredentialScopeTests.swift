import CTXCore
import Foundation

func testExportingCredentialsNeverWritesADefaultProfile() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-scope-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config")
    let credentialsURL = directory.appendingPathComponent("credentials")
    try! """
    [sso-session portal]
    sso_start_url = https://d-1111111111.awsapps.com/start/#
    sso_region = us-east-1

    [profile chosen]
    sso_session = portal
    sso_account_id = 111122223333
    sso_role_name = ReadOnly
    """.write(to: configURL, atomically: true, encoding: .utf8)
    try! "".write(to: credentialsURL, atomically: true, encoding: .utf8)

    let service = AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL)
    _ = try! service.storeExportedCredentials(
        #"{"AccessKeyId":"EXAMPLE","SecretAccessKey":"example-secret","SessionToken":"example-token"}"#,
        profileName: "chosen"
    )

    let config = try! String(contentsOf: configURL, encoding: .utf8)
    let credentials = try! String(contentsOf: credentialsURL, encoding: .utf8)

    // The chosen profile gets its credentials...
    assert(credentials.contains("[chosen]"))
    assert(credentials.contains("EXAMPLE"))

    // ...and nothing is mirrored into [default]. That one global value is shared by
    // every shell, script and background process on the machine, so writing it changed
    // what a bare `aws` command meant for terminals opened hours earlier - silently.
    // Scope belongs to the shell now, through AWS_PROFILE.
    assert(!config.contains("[default]"))
    assert(!credentials.contains("[default]"))
}
