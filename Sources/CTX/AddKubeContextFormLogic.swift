import CTXCore
import SwiftUI

extension AddKubeContextView {
    static func eksRegion(from text: String) -> String {
        let lower = text.lowercased()
        if let range = lower.range(of: #"[a-z]{2}-(?:gov-)?[a-z]+-\d"#, options: .regularExpression) {
            return String(lower[range])
        }
        if let range = lower.range(of: #"[a-z]{2}-[a-z]+\d"#, options: .regularExpression) {
            let matched = String(lower[range])
            // Standardize format like us-east1 to us-east-1
            if let lastDigit = matched.last, let splitIdx = matched.dropLast().indices.last {
                return String(matched[..<splitIdx]) + "-" + String(lastDigit)
            }
            return matched
        }
        return ""
    }

    var awsProfiles: [CloudProfile] {
        store.profiles
            .filter { $0.provider == .aws }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    var hasExistingCredential: Bool {
        if case .edit(let profile) = mode {
            return profile.hasKubernetesCredentials
        }
        return false
    }

    var showsBearerTokenField: Bool {
        guard !isDuplicating else { return false }
        return KubeContextBearerTokenIntent.showsTokenField(
            hasExistingCredential: hasExistingCredential,
            isReplacementRequested: isReplacingBearerToken
        )
    }

    var isDuplicating: Bool {
        if case .duplicate = mode {
            return true
        }
        return false
    }

    func autoDetectAuthMode(from text: String) {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return }

        if lower.contains("arn:aws:eks") || lower.contains("eks") {
            authMode = .cloudIAM
            let region = Self.eksRegion(from: text)
            if !region.isEmpty {
                awsRegion = region
            }
        } else if lower.contains("sdm") {
            authMode = .strongDM
        } else if lower.contains("teleport") || lower.contains("tsh") {
            authMode = .teleport
        } else if lower.contains("gke") {
            authMode = .gcpGKE
        } else if lower.contains("aks") {
            authMode = .azureAKS
        }
    }

    func setupInitialValues() {
        switch mode {
        case .create:
            awsProfile = store.activeAWSProfile
        case .edit(let profile), .duplicate(let profile):
            name = if case .duplicate = mode {
                store.suggestedKubeContextDuplicateName(for: profile)
            } else {
                profile.name
            }
            cluster = profile.accountID // accountID is cluster
            user = profile.roleName     // roleName is user
            namespace = profile.region  // region is namespace
            skipTLSVerification = store.kubernetesContexts
                .first(where: { $0.contextName == profile.name })?
                .skipTLSVerification ?? false

            if profile.kubernetesCredentialKind == .bearerToken {
                authMode = .bearerToken
            } else if profile.usesStrongDM {
                authMode = .strongDM
            } else if profile.usesTeleport {
                authMode = .teleport
            } else if profile.provider == .aws || cluster.contains("arn:aws:eks") || name.lowercased().contains("eks") || profile.name.lowercased().contains("aws") {
                authMode = .cloudIAM
                awsProfile = store.activeAWSProfile
                awsRegion = Self.eksRegion(from: cluster)
            } else if cluster.contains("gke") || name.lowercased().contains("gke") {
                authMode = .gcpGKE
            } else if cluster.contains("aks") || name.lowercased().contains("aks") {
                authMode = .azureAKS
            } else {
                authMode = .proxyTunnel
            }

            if !cluster.isEmpty {
                isResolvingServer = true
                resolveTask = Task { @MainActor in
                    let resolved = await store.resolveKubeServer(for: cluster, contextName: profile.name)
                    guard !Task.isCancelled else { return }
                    server = resolved
                    isResolvingServer = false
                }
            }
        }
    }

    func save() {
        isSaving = true
        errorMessage = ""

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                switch mode {
                case .create:
                    let credential: KubeConfigCredential = switch authMode {
                    case .proxyTunnel, .strongDM, .teleport, .gcpGKE, .azureAKS:
                        .internalProxy
                    case .bearerToken:
                        .bearerToken(token.isEmpty ? nil : token)
                    case .cloudIAM:
                        .awsEKS(
                            region: awsRegion.trimmingCharacters(in: .whitespaces),
                            profile: awsProfile.trimmingCharacters(in: .whitespaces)
                        )
                    }

                    try await store.addKubeContext(
                        name: name.trimmingCharacters(in: .whitespaces),
                        server: server.trimmingCharacters(in: .whitespaces),
                        cluster: cluster.trimmingCharacters(in: .whitespaces),
                        user: user.trimmingCharacters(in: .whitespaces),
                        namespace: namespace.trimmingCharacters(in: .whitespaces),
                        credential: credential,
                        skipTLSVerification: skipTLSVerification,
                        targetFolder: selectedFolder,
                        from: origin
                    )
                case .duplicate(let profile):
                    try await store.duplicateKubeContext(
                        profile,
                        newName: name,
                        targetFolder: selectedFolder,
                        from: origin
                    )
                case .edit(let profile):
                    let credentialUpdate: KubeConfigCredentialUpdate = switch authMode {
                    case .bearerToken:
                        KubeContextBearerTokenIntent.credentialUpdate(
                            hasExistingCredential: profile.hasKubernetesCredentials,
                            isReplacementRequested: isReplacingBearerToken,
                            token: token
                        )
                    case .cloudIAM:
                        .replace(
                            .awsEKS(
                                region: awsRegion.trimmingCharacters(in: .whitespaces),
                                profile: awsProfile.trimmingCharacters(in: .whitespaces)
                            )
                        )
                    case .proxyTunnel, .strongDM, .teleport, .gcpGKE, .azureAKS:
                        .replace(.internalProxy)
                    }
                    try await store.updateKubeContext(
                        profile,
                        newName: name.trimmingCharacters(in: .whitespaces),
                        server: server.trimmingCharacters(in: .whitespaces),
                        cluster: cluster.trimmingCharacters(in: .whitespaces),
                        user: user.trimmingCharacters(in: .whitespaces),
                        namespace: namespace.trimmingCharacters(in: .whitespaces),
                        credentialUpdate: credentialUpdate,
                        skipTLSVerification: skipTLSVerification == (
                            store.kubernetesContexts
                                .first(where: { $0.contextName == profile.name })?
                                .skipTLSVerification ?? false
                        ) ? nil : skipTLSVerification,
                        targetFolder: selectedFolder,
                        from: origin
                    )
                }
                guard !Task.isCancelled else { return }
                isSaving = false
                saveTask = nil
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isSaving = false
                saveTask = nil
            }
        }
    }
}
