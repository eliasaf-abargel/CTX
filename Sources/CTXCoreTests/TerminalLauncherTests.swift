import CTXCore
import Foundation

private func profile(_ provider: CloudProvider, _ name: String, region: String = "") -> CloudProfile {
    var profile = CloudProfile(provider: provider, name: name)
    profile.region = region
    return profile
}

func testTerminalScopeIsOneEnvironmentVariablePerProvider() {
    let aws = try! TerminalLauncher.environment(for: profile(.aws, "example", region: "us-east-1"), base: [:])
    assert(aws["AWS_PROFILE"] == "example")
    assert(aws["AWS_REGION"] == "us-east-1")
    assert(aws["AWS_DEFAULT_REGION"] == "us-east-1")

    // No region on the profile means the shell inherits whatever the person set.
    let regionless = try! TerminalLauncher.environment(for: profile(.aws, "example"), base: [:])
    assert(regionless["AWS_PROFILE"] == "example")
    assert(regionless["AWS_REGION"] == nil)

    let gcp = try! TerminalLauncher.environment(for: profile(.gcp, "example"), base: [:])
    assert(gcp["CLOUDSDK_ACTIVE_CONFIG_NAME"] == "example")

    let kube = try! TerminalLauncher.environment(
        for: profile(.kubernetes, "example"),
        kubeconfigPath: "/tmp/example-kubeconfig",
        base: [:]
    )
    assert(kube["KUBECONFIG"] == "/tmp/example-kubeconfig")
}

func testTerminalScopeKeepsConfiguredPathOverrides() {
    // A person who moved their config files keeps seeing the same ones in the shell.
    let base = ["AWS_CONFIG_FILE": "/tmp/elsewhere/config"]
    let environment = try! TerminalLauncher.environment(for: profile(.aws, "example"), base: base)
    assert(environment["AWS_CONFIG_FILE"] == "/tmp/elsewhere/config")
    assert(environment["AWS_PROFILE"] == "example")
}

func testAzureIsRefusedRatherThanFaked() {
    // az has no per-shell switch, so scoping a terminal to a subscription would be a
    // promise this cannot keep. Refusing is honest; inventing a variable is not.
    assert(!TerminalLauncher.canOpenTerminal(for: profile(.azure, "example")))
    assert(TerminalLauncher.canOpenTerminal(for: profile(.aws, "example")))

    var refused = false
    do {
        _ = try TerminalLauncher.environment(for: profile(.azure, "example"), base: [:])
    } catch {
        refused = true
    }
    assert(refused)
}

func testLaunchScriptQuotesValuesAndHandsOverToTheLoginShell() {
    let awkward = profile(.aws, "it's-example")
    let script = TerminalLauncher.launchScript(
        for: awkward,
        environment: try! TerminalLauncher.environment(for: awkward, base: [:])
    )

    // A quote in a profile name must not break out of the assignment.
    assert(script.contains(#"export AWS_PROFILE='it'\''s-example'"#))
    assert(script.hasPrefix("#!/bin/sh"))
    // The person keeps their own shell, prompt and aliases.
    assert(script.contains(#"exec "${SHELL:-/bin/zsh}" -l"#))

    // Nothing visible is written. Output during shell startup is what instant-prompt
    // frameworks warn about, and a banner was being redrawn away regardless. The window
    // title is an OSC escape, which draws nothing into the buffer.
    assert(!script.contains("clear"))
    assert(!script.contains("echo"))
    assert(script.contains(#"printf '\033]0;%s\007'"#))
    // Quoted, so the apostrophe cannot close the string and run the rest as commands.
    assert(script.contains(#"'AWS · it'\''s-example'"#))
}

func testScriptNameIsReadableAndCannotEscapeItsDirectory() {
    // Terminal titles the window after the script, so the name is what the person sees.
    assert(TerminalLauncher.scriptName(for: profile(.aws, "prod-is")) == "prod-is.command")
    assert(TerminalLauncher.scriptName(for: profile(.gcp, "team_sandbox.v2")) == "team_sandbox.v2.command")

    // A profile name is not trusted input: a slash or "..", left alone, would write the
    // script outside the directory it is meant to live in.
    for hostile in ["../../escape", "a/b", "..", "/", "  "] {
        let name = TerminalLauncher.scriptName(for: profile(.aws, hostile))
        assert(!name.contains("/"))
        assert(!name.hasPrefix("."))
        assert(name.hasSuffix(".command"))
    }
}

func testTerminalChoiceFallsBackWhenTheChosenAppIsGone() {
    let installed = TerminalApplication.installed()
    assert(!installed.isEmpty, "macOS always ships Terminal.app")

    // An empty preference means "whichever is installed".
    assert(TerminalApplication.resolved(preferredBundlePath: "") == installed.first)

    // A choice that no longer exists - the app was deleted since it was picked - falls
    // back rather than failing to open anything.
    assert(TerminalApplication.resolved(preferredBundlePath: "/Applications/Deleted.app") == installed.first)

    // An installed choice is honoured.
    let chosen = installed[installed.count - 1]
    assert(TerminalApplication.resolved(preferredBundlePath: chosen.bundlePath) == chosen)
}


func runTerminalLauncherTests() {
    testTerminalScopeIsOneEnvironmentVariablePerProvider()
    testTerminalScopeKeepsConfiguredPathOverrides()
    testAzureIsRefusedRatherThanFaked()
    testLaunchScriptQuotesValuesAndHandsOverToTheLoginShell()
    testScriptNameIsReadableAndCannotEscapeItsDirectory()
    testTerminalChoiceFallsBackWhenTheChosenAppIsGone()
}
