import Foundation

/// Where the provider CLIs actually live.
///
/// A GUI app launched from Finder inherits launchd's `PATH` — `/usr/bin:/bin:
/// /usr/sbin:/sbin` — not the `PATH` the user's shell builds from their profile.
/// So "aws works in my terminal but CTX says it isn't installed" is the normal
/// case, not an edge case, and every CLI has to be located by looking where its
/// installer actually puts it.
public enum CLIToolPaths {
    public static var searchDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.rd/bin",              // Rancher Desktop
            "\(home)/google-cloud-sdk/bin", // gcloud's own tarball installer
            "\(home)/.local/bin",           // pipx / uv
            "/opt/homebrew/bin",            // Homebrew, Apple silicon
            "/usr/local/bin",               // Homebrew on Intel, AWS CLI pkg, Docker Desktop
            "/opt/local/bin",               // MacPorts
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    /// First executable named `binaryName`, searching `extraDirs` (typically the
    /// inherited `PATH`) before the known install locations. `nil` means the tool
    /// is genuinely not on this machine — worth saying so plainly rather than
    /// letting `env` fail with "No such file or directory".
    public static func resolve(_ binaryName: String, extraDirs: [String] = []) -> String? {
        let fileManager = FileManager.default
        for dir in extraDirs + searchDirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent(binaryName)
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func dirs(fromPathVariable path: String?) -> [String] {
        (path ?? "").split(separator: ":").map(String.init)
    }
}
