import Foundation

/// Structured, DEBUG-only timing log for diagnosing load/timeout/cache behavior.
///
/// Format: `[CTX perf] step=<name> context=<contextHash> namespace=<namespace|all|cluster>
/// kind=<kind> cache=<hit|miss|stale|none> durationMs=<ms> outcome=<success|timeout|error|cancelled>`
///
/// Never logs kubeconfig contents, tokens, secrets, or the real context/cluster name —
/// only a short one-way hash of the context identity, safe to paste into a bug report.
public enum CTXPerfLog {
    public enum Cache: String {
        case hit, miss, stale, none
    }

    public enum Outcome: String {
        case success, timeout, error, cancelled
    }

    public static func log(
        step: String,
        contextID: String,
        namespace: String,
        kind: String,
        cache: Cache,
        durationMs: Int,
        outcome: Outcome
    ) {
#if DEBUG
        print("[CTX perf] step=\(step) context=\(safeContextHash(contextID)) namespace=\(namespace) kind=\(kind) cache=\(cache.rawValue) durationMs=\(durationMs) outcome=\(outcome.rawValue)")
#endif
    }

    /// Short, deterministic (per string, not per process), one-way identifier —
    /// FNV-1a truncated to 8 hex characters. Not reversible to the real context name.
    public static func safeContextHash(_ contextID: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in contextID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%08x", hash & 0xFFFF_FFFF)
    }
}
