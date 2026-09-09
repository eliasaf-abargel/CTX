import Foundation

extension ProfileStore {
    /// Opens a terminal scoped to `profile`, off the main actor - the launch does disk
    /// I/O and spawns a process, neither of which belongs between a click and a redraw.
    @MainActor
    public func openTerminal(for profile: CloudProfile) {
        let kubeconfigPath = profile.provider == .kubernetes
            ? kubeconfigPath(for: profile.name)
            : nil
        let terminal = defaults.string(forKey: CTXDefaultsKey.terminalApplication) ?? ""

        Task.detached(priority: .userInitiated) {
            let message: String
            do {
                try TerminalLauncher.openTerminal(
                    for: profile,
                    kubeconfigPath: kubeconfigPath,
                    preferredTerminalBundlePath: terminal
                )
                message = "Opened a terminal using \(profile.name)"
            } catch {
                message = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                self?.lastMessage = message
            }
        }
    }
}
