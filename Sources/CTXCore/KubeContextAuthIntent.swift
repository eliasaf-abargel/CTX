import Foundation

/// The bearer-token decisions the Kubernetes context editor has to make, kept out
/// of the view so they are made in one place and can be tested.
///
/// CTX never reads a stored credential's value, so the editor has to state intent
/// rather than diff it. Two rules follow from that: a context that already has a
/// credential keeps it until the user explicitly asks to replace it, and a context
/// with *no* credential must still be able to gain one — the editor used to hide
/// the token field in that case, which left the context permanently unauthenticated
/// with no way to fix it from the UI.
public enum KubeContextBearerTokenIntent {
    /// Whether the editor should offer a token field at all.
    public static func showsTokenField(hasExistingCredential: Bool, isReplacementRequested: Bool) -> Bool {
        !hasExistingCredential || isReplacementRequested
    }

    /// A replacement is issued only for an explicitly typed, non-empty token; every
    /// other combination preserves whatever is already in the kubeconfig.
    public static func credentialUpdate(
        hasExistingCredential: Bool,
        isReplacementRequested: Bool,
        token: String
    ) -> KubeConfigCredentialUpdate {
        guard showsTokenField(
            hasExistingCredential: hasExistingCredential,
            isReplacementRequested: isReplacementRequested
        ) else {
            return .preserveExisting
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .preserveExisting }
        return .replace(.bearerToken(token))
    }
}
