import Foundation

/// Utilities for converting Git repository remote URLs (SSH, HTTPS, Git protocol)
/// and target revisions/branches/commits into clickable browser URLs.
public enum GitRepositoryURLHelper {
    public static func webURL(from rawURL: String, revision: String? = nil) -> URL? {
        var str = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }

        // Strip ssh:// prefix if present
        if str.lowercased().hasPrefix("ssh://") {
            str = String(str.dropFirst("ssh://".count))
        }

        var host = ""
        var path = ""

        if str.lowercased().hasPrefix("git@") {
            let withoutGit = String(str.dropFirst(4))
            if let colonIdx = withoutGit.firstIndex(of: ":") {
                host = String(withoutGit[..<colonIdx])
                path = String(withoutGit[withoutGit.index(after: colonIdx)...])
            } else if let slashIdx = withoutGit.firstIndex(of: "/") {
                host = String(withoutGit[..<slashIdx])
                path = String(withoutGit[withoutGit.index(after: slashIdx)...])
            } else {
                return nil
            }
        } else if let url = URL(string: str), let urlHost = url.host {
            host = urlHost
            path = url.path
            if path.hasPrefix("/") {
                path = String(path.dropFirst())
            }
        } else {
            return nil
        }

        if path.hasSuffix(".git") {
            path = String(path.dropLast(4))
        }

        guard !host.isEmpty, !path.isEmpty else { return nil }

        var webString = "https://\(host)/\(path)"

        if let rev = revision?.trimmingCharacters(in: .whitespacesAndNewlines), !rev.isEmpty, rev != "HEAD" {
            let isCommitHash = (rev.count == 7 || rev.count == 8 || rev.count == 40) && rev.allSatisfy { $0.isHexDigit }
            if isCommitHash {
                webString += "/commit/\(rev)"
            } else {
                webString += "/tree/\(rev)"
            }
        }

        return URL(string: webString)
    }
}
