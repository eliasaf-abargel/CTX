import Foundation

public enum TerminalLauncherError: LocalizedError {
    case unsupportedProvider(CloudProvider)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            "\(provider.rawValue) has no per-shell switch, so a terminal cannot be scoped to it"
        case .launchFailed(let reason):
            "Could not open a terminal: \(reason)"
        }
    }
}

/// Opens a terminal already scoped to one profile.
///
/// The scope is an environment variable, which lives and dies with that shell, so two
/// terminals can sit in two accounts at once without touching each other or `~/.aws`.
/// The opposite of a `[default]` profile, which every shell silently shares.
public enum TerminalLauncher {
    /// The variables that scope a shell to `profile`.
    ///
    /// Azure is absent on purpose: `az` switches subscriptions by writing its own
    /// state, and has no per-shell equivalent of `AWS_PROFILE`, so claiming to scope a
    /// terminal to an Azure subscription would be a promise this cannot keep.
    public static func environment(
        for profile: CloudProfile,
        kubeconfigPath: String? = nil,
        base: [String: String] = ProviderCommandEnvironment.overrides()
    ) throws -> [String: String] {
        var environment = base

        switch profile.provider {
        case .aws:
            environment["AWS_PROFILE"] = profile.name
            if !profile.region.isEmpty {
                environment["AWS_REGION"] = profile.region
                environment["AWS_DEFAULT_REGION"] = profile.region
            }
        case .gcp:
            environment["CLOUDSDK_ACTIVE_CONFIG_NAME"] = profile.name
        case .kubernetes:
            if let kubeconfigPath, !kubeconfigPath.isEmpty {
                environment["KUBECONFIG"] = kubeconfigPath
            }
        case .azure:
            throw TerminalLauncherError.unsupportedProvider(.azure)
        }

        return environment
    }

    public static func canOpenTerminal(for profile: CloudProfile) -> Bool {
        profile.provider != .azure
    }

    /// A script rather than AppleScript: no automation permission, and it works with
    /// whichever terminal the person prefers.
    public static func openTerminal(
        for profile: CloudProfile,
        kubeconfigPath: String? = nil,
        preferredTerminalBundlePath: String = ""
    ) throws {
        let environment = try environment(for: profile, kubeconfigPath: kubeconfigPath)
        let script = launchScript(for: profile, environment: environment)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctx-terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        discardStaleScripts(in: directory)
        let scriptURL = directory.appendingPathComponent(scriptName(for: profile))

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        guard let terminal = TerminalApplication.resolved(preferredBundlePath: preferredTerminalBundlePath) else {
            throw TerminalLauncherError.launchFailed("no terminal application was found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", terminal.bundlePath, scriptURL.path]
        do {
            try process.run()
        } catch {
            throw TerminalLauncherError.launchFailed(error.localizedDescription)
        }
    }

    /// The script the terminal will run. Public so the app can show it: a person is
    /// entitled to see exactly what is about to execute on their machine.
    public static func launchScript(
        for profile: CloudProfile,
        environment: [String: String]
    ) -> String {
        let exports = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuoted($0.value))" }
            .joined(separator: "\n")

        // Sets the environment and hands over. Nothing is printed and the screen is not
        // cleared: writing to the console during shell startup is what frameworks like
        // powerlevel10k's instant prompt warn about, and a banner was being wiped by the
        // redraw anyway. The profile is already in the window title, from the script's
        // own name. Someone's prompt, colours and aliases are theirs, and an rc that
        // exports the same variable still wins.
        // The title is an OSC escape, not visible output, so it cannot collide with an
        // instant-prompt redraw the way a printed banner did. A shell that manages its
        // own title - oh-my-zsh does, unless DISABLE_AUTO_TITLE is set - overwrites it
        // on the first prompt, which costs nothing; a bare shell keeps it. Prompt
        // frameworks show the profile natively from the variable already exported.
        let title = "\(profile.provider.rawValue) · \(profile.name)"
        return """
        #!/bin/sh
        \(exports)
        printf '\\033]0;%s\\007' \(shellQuoted(title))
        exec "${SHELL:-/bin/zsh}" -l
        """
    }

    /// Terminal titles the window after the script, so the name is what the person sees.
    /// Sanitised because a profile name is untrusted: `a/b` would escape the directory.
    public static func scriptName(for profile: CloudProfile) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(profile.name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return (safe.isEmpty ? "ctx-profile" : safe) + ".command"
    }

    internal static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The terminal reads a script the moment it opens, so anything an hour old has been
    /// consumed. Without this, every terminal ever opened would leave a file behind.
    private static func discardStaleScripts(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        for url in contents where url.pathExtension == "command" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
