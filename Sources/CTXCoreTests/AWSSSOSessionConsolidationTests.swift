import CTXCore
import Foundation

func testProfilesOnOneIdentityCenterShareASingleSSOSession() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-awsconfig-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config")

    func draft(_ name: String, _ account: String, _ portal: String) -> AWSProfileDraft {
        var draft = AWSProfileDraft()
        draft.name = name
        draft.ssoStartURL = portal
        draft.ssoRegion = "us-east-1"
        draft.accountID = account
        draft.roleName = "AdministratorAccess"
        draft.defaultRegion = "us-east-1"
        return draft
    }

    func occurrences(_ needle: String, _ haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    let portal = "https://d-1111111111.awsapps.com/start/#"
    try! AWSConfigWriter.appendProfile(draft("alpha", "111122223333", portal), to: url)
    try! AWSConfigWriter.appendProfile(draft("beta", "222233334444", portal), to: url)
    try! AWSConfigWriter.appendProfile(
        draft("gamma", "333344445555", "https://d-2222222222.awsapps.com/start/#"),
        to: url
    )

    let text = try! String(contentsOf: url, encoding: .utf8)
    // One session per portal, not one per profile - two portals, two sessions.
    assert(occurrences("[sso-session ", text) == 2)
    assert(occurrences("[sso-session alpha]", text) == 1)
    assert(occurrences("[sso-session beta]", text) == 0)
    assert(text.contains("[profile beta]"))
    assert(occurrences("sso_session = alpha", text) == 2)
    assert(text.contains("[sso-session gamma]"))

    // Editing a profile must not remove the session its sibling still points at.
    try! AWSConfigWriter.updateProfile(
        originalName: "beta",
        draft: draft("beta", "222233334444", portal),
        to: url
    )
    let edited = try! String(contentsOf: url, encoding: .utf8)
    assert(edited.contains("[sso-session alpha]"))
    assert(occurrences("[profile beta]", edited) == 1)
    assert(occurrences("sso_session = alpha", edited) == 2)
}


func testConsolidateCollapsesDuplicateSessionsAndLeavesCleanConfigsAlone() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-awsconfig-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config")

    // A config as older versions wrote it: one session per profile, two portals.
    try! """
    [sso-session alpha]
    sso_start_url = https://d-1111111111.awsapps.com/start/#
    sso_region = us-east-1
    sso_registration_scopes = sso:account:access

    [profile alpha]
    sso_session = alpha
    sso_account_id = 111122223333
    sso_role_name = ReadOnly
    region = us-east-1

    [sso-session beta]
    sso_start_url = https://d-1111111111.awsapps.com/start/#
    sso_region = us-east-1
    sso_registration_scopes = sso:account:access

    [profile beta]
    sso_session = beta
    sso_account_id = 222233334444
    sso_role_name = ReadOnly
    region = us-east-1

    [sso-session gamma]
    sso_start_url = https://d-2222222222.awsapps.com/start/#
    sso_region = eu-west-1
    sso_registration_scopes = sso:account:access

    [profile gamma]
    sso_session = gamma
    sso_account_id = 333344445555
    sso_role_name = ReadOnly
    region = eu-west-1

    [default]
    sso_session = beta
    sso_account_id = 222233334444
    sso_role_name = ReadOnly
    """.write(to: url, atomically: true, encoding: .utf8)

    let merged = try! AWSConfigWriter.consolidateSSOSessions(in: url)
    assert(merged.count == 1)
    assert(merged[0].canonicalSession == "alpha")
    assert(merged[0].mergedSessions == ["beta"])
    // The default profile is spelled [default], not [profile default]; leaving it behind
    // points it at a deleted session and every CLI call fails, whatever profile is asked for.
    assert(merged[0].repointedProfiles == ["beta", "default"])

    let text = try! String(contentsOf: url, encoding: .utf8)
    assert(text.contains("[sso-session alpha]"))
    assert(!text.contains("[sso-session beta]"))
    assert(text.contains("[profile beta]"))
    assert(text.contains("sso_session = alpha"))
    // A different portal keeps its own session.
    assert(text.contains("[sso-session gamma]"))
    assert(text.contains("sso_session = gamma"))
    // Unrelated profile settings survive untouched.
    assert(text.contains("sso_account_id = 222233334444"))
    // No section may still reference a session that was removed.
    assert(!text.contains("sso_session = beta"))
    assert(text.contains("[default]"))

    // Second run is a no-op: nothing left to merge.
    assert(try! AWSConfigWriter.consolidateSSOSessions(in: url).isEmpty)
    assert(try! String(contentsOf: url, encoding: .utf8) == text)
}


func testConsolidateLeavesEverythingItDoesNotOwnByteForByte() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-awsconfig-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A config a person wrote by hand: comments, static keys, credential_process,
    // an assumed-role chain, and a region CTX never asked about.
    let handWritten = """
    # work accounts - do not reorder
    [sso-session alpha]
    sso_start_url = https://d-1111111111.awsapps.com/start/#
    sso_region = us-east-1
    sso_registration_scopes = sso:account:access

    [profile one]
    sso_session = alpha
    sso_account_id = 111122223333
    sso_role_name = ReadOnly
    region = us-east-1

    ; legacy static keys, rotated by hand
    [profile vendor]
    aws_access_key_id = AKIAIOSFODNN7EXAMPLE
    region = eu-west-1

    [profile via-helper]
    credential_process = /opt/bin/creds --json
    region = ap-south-1

    [profile escalated]
    role_arn = arn:aws:iam::444455556666:role/Escalated
    source_profile = one
    duration_seconds = 3600
    """

    // Case 1: nothing to merge - the file must come back untouched.
    let clean = directory.appendingPathComponent("clean")
    try! handWritten.write(to: clean, atomically: true, encoding: .utf8)
    let before = try! String(contentsOf: clean, encoding: .utf8)
    assert(try! AWSConfigWriter.consolidateSSOSessions(in: clean).isEmpty)
    assert(try! String(contentsOf: clean, encoding: .utf8) == before)

    // Case 2: add a duplicate session; only that block may move.
    let messy = directory.appendingPathComponent("messy")
    try! (handWritten + """


    [sso-session beta]
    sso_start_url = https://d-1111111111.awsapps.com/start/#
    sso_region = us-east-1
    sso_registration_scopes = sso:account:access

    [profile two]
    sso_session = beta
    sso_account_id = 222233334444
    sso_role_name = ReadOnly
    """).write(to: messy, atomically: true, encoding: .utf8)

    assert(try! AWSConfigWriter.consolidateSSOSessions(in: messy).count == 1)
    let after = try! String(contentsOf: messy, encoding: .utf8)

    // Comments survive, including the ; style.
    assert(after.contains("# work accounts - do not reorder"))
    assert(after.contains("; legacy static keys, rotated by hand"))
    // Non-SSO profiles are not rewritten in any way.
    assert(after.contains("aws_access_key_id = AKIAIOSFODNN7EXAMPLE"))
    assert(after.contains("credential_process = /opt/bin/creds --json"))
    assert(after.contains("role_arn = arn:aws:iam::444455556666:role/Escalated"))
    assert(after.contains("source_profile = one"))
    assert(after.contains("duration_seconds = 3600"))
    assert(after.contains("region = ap-south-1"))
    // Only the duplicate session is gone; the profile that used it is repointed.
    assert(!after.contains("[sso-session beta]"))
    assert(after.contains("[profile two]"))
    assert(after.contains("sso_session = alpha"))
    assert(!after.contains("sso_session = beta"))
}



func runAWSSSOSessionConsolidationTests() {
            }
