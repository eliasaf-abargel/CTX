import CTXCore
import Foundation

private func awsProfile(_ name: String, startURL: String) -> CloudProfile {
    var profile = CloudProfile(provider: .aws, name: name)
    profile.ssoStartURL = startURL
    return profile
}

func testAccessFromThisMachineIsTheCredentialClockNotTheTokenClock() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-session-tests-\(UUID().uuidString)")
    let cache = directory.appendingPathComponent("cache")
    try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let portal = "https://d-1111111111.awsapps.com/start/#"
    let formatter = ISO8601DateFormatter()
    let tokenEnds = Date().addingTimeInterval(57 * 60)
    let credentialsEnd = Date().addingTimeInterval(12 * 3600)

    // A real access token, carrying a refresh token, plus a client registration - which
    // also has an "expiresAt", seventy-five days out, and is not a token at all.
    try! #"{"accessToken":"example","refreshToken":"r","startUrl":"\#(portal)","region":"us-east-1","expiresAt":"\#(formatter.string(from: tokenEnds))"}"#
        .write(to: cache.appendingPathComponent("token.json"), atomically: true, encoding: .utf8)
    try! #"{"clientId":"example","clientSecret":"secret","expiresAt":"\#(formatter.string(from: Date().addingTimeInterval(75 * 86400)))"}"#
        .write(to: cache.appendingPathComponent("registration.json"), atomically: true, encoding: .utf8)

    let credentials = directory.appendingPathComponent("credentials")
    try! """
    [one]
    aws_access_key_id = EXAMPLE
    aws_session_expiration = \(formatter.string(from: credentialsEnd))
    """.write(to: credentials, atomically: true, encoding: .utf8)

    let service = AWSSessionExpirationService(credentialsURL: credentials, ssoCacheURL: cache)
    let one = awsProfile("one", startURL: portal)

    // What governs access from this machine is the exported credentials - twelve hours -
    // and each profile carries its own, so one connected an hour ago has an hour less.
    let access = service.sessionExpiry(for: one)!
    assert(abs(access.timeIntervalSince(credentialsEnd)) < 2)

    // The access token's hourly expiry is not a deadline: it carries a refresh token, so
    // the CLI renews it with no browser. Reporting it as one told people they had an
    // hour when they had twelve.
    if case .valid(let until) = service.ssoTokenState(for: one) {
        assert(abs(until.timeIntervalSince(tokenEnds)) < 2)
    } else {
        assert(false, "a token an hour from expiry, with a refresh token, is valid")
    }
    let expiredButRefreshable = AWSSessionExpirationService.tokenState(
        expiresAt: Date().addingTimeInterval(-60),
        refreshToken: "r",
        registrationExpiresAt: Date().addingTimeInterval(86400),
        now: Date()
    )
    assert(expiredButRefreshable == .refreshable)

    // Only a dead registration, or no refresh token, actually needs a browser.
    assert(AWSSessionExpirationService.tokenState(
        expiresAt: Date().addingTimeInterval(-60),
        refreshToken: nil,
        registrationExpiresAt: Date().addingTimeInterval(86400),
        now: Date()
    ) == .needsInteractive)
}

func testProfilesOnOnePortalShareOneSignIn() {
    let portal = "https://d-1111111111.awsapps.com/start/#"
    let elsewhere = "https://d-2222222222.awsapps.com/start/#"
    let one = awsProfile("one", startURL: portal)
    let all = [
        one,
        awsProfile("two", startURL: portal),
        awsProfile("three", startURL: portal.uppercased()),
        awsProfile("far", startURL: elsewhere),
        CloudProfile(provider: .gcp, name: "gcp-one")
    ]

    let service = AWSSessionExpirationService()
    let shared = service.profilesSharingSignIn(with: one, among: all).map(\.name).sorted()

    // Letting the portal lapse takes all of these at once, so the app can say so before
    // someone disconnects one and is surprised by the others going with it.
    assert(shared == ["three", "two"])
}

func testAnExpiredSignInIsReportedForAProfileThatOnlyNamesASession() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-expiry-tests-\(UUID().uuidString)")
    let cache = directory.appendingPathComponent("cache")
    try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let portal = "https://d-1111111111.awsapps.com/start/#"
    let formatter = ISO8601DateFormatter()
    let expiredAt = Date().addingTimeInterval(-27 * 3600)

    try! #"{"accessToken":"example","startUrl":"\#(portal)","region":"us-east-1","expiresAt":"\#(formatter.string(from: expiredAt))"}"#
        .write(to: cache.appendingPathComponent("token.json"), atomically: true, encoding: .utf8)

    // A configuration after consolidation: the profile names a session, and only the
    // session block carries the start URL. Losing that link would leave the profile
    // with no expiry at all - and a profile with no expiry is skipped, never marked
    // expired, so it kept reporting connected long after its token had died.
    let config = """
    [sso-session shared]
    sso_start_url = \(portal)
    sso_region = us-east-1

    [profile one]
    sso_session = shared
    sso_account_id = 111122223333
    sso_role_name = ReadOnly
    """
    let parsed = AWSConfigParser.parse(config)
    let one = parsed.first { $0.name == "one" }!
    assert(one.ssoStartURL == portal, "the start URL must be resolved through the session block")

    let credentials = directory.appendingPathComponent("credentials")
    try! "".write(to: credentials, atomically: true, encoding: .utf8)
    let service = AWSSessionExpirationService(credentialsURL: credentials, ssoCacheURL: cache)

    let snapshot = service.snapshot(for: [one])!
    let reported = snapshot.expiryByProfileName["one"]
    assert(reported != nil, "a profile whose sign-in has expired must appear in the snapshot")
    assert(reported!.timeIntervalSinceNow < 0, "and it must be reported as already past")
}

