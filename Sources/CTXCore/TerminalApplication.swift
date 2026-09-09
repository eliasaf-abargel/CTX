import Foundation

/// A terminal CTX can open a scoped shell in.
public struct TerminalApplication: Identifiable, Hashable, Sendable {
    public var id: String { bundlePath }
    public let name: String
    public let bundlePath: String

    /// Terminals in the order they are offered. Apple's own is last because someone who
    /// installed another one almost certainly prefers it.
    private static let known: [(name: String, path: String)] = [
        ("iTerm", "/Applications/iTerm.app"),
        ("Ghostty", "/Applications/Ghostty.app"),
        ("Warp", "/Applications/Warp.app"),
        ("WezTerm", "/Applications/WezTerm.app"),
        ("Alacritty", "/Applications/Alacritty.app"),
        ("kitty", "/Applications/kitty.app"),
        ("Hyper", "/Applications/Hyper.app"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app")
    ]

    public static func installed() -> [TerminalApplication] {
        known
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { TerminalApplication(name: $0.name, bundlePath: $0.path) }
    }

    /// The chosen terminal, or the first installed one when the choice is empty or the
    /// app it named has since been removed.
    public static func resolved(preferredBundlePath: String) -> TerminalApplication? {
        let available = installed()
        if !preferredBundlePath.isEmpty,
           let match = available.first(where: { $0.bundlePath == preferredBundlePath }) {
            return match
        }
        return available.first
    }
}
