import Foundation

public enum KubeConfigMutationError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    /// The replacement credential was written successfully, but a field left over
    /// from the previous authentication method could not be cleared afterwards.
    case staleCredentialField(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .staleCredentialField(let message): message
        }
    }
}

public enum KubeConfigCredential: Equatable, Sendable {
    case internalProxy
    case bearerToken(String?)
    case awsEKS(region: String, profile: String?)
}

public enum KubeConfigCredentialUpdate: Equatable, Sendable {
    case preserveExisting
    case replace(KubeConfigCredential)
    case remove
}
