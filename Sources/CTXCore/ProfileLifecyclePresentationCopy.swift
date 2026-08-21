extension ProfileStore {
    internal func providerSignOutConfirmation(for profile: CloudProfile) -> ProviderSignOutConfirmation? {
        switch profile.provider {
        case .aws:
            let account = profile.accountID.isEmpty
                ? profile.name
                : "\(profile.name) (account \(profile.accountID))"
            return ProviderSignOutConfirmation(
                profile: profile,
                title: "Sign out from AWS?",
                warning: "AWS CLI logout clears all cached AWS SSO sessions, not only \(account). CTX will also remove temporary credential sections it exported, including default.",
                confirmLabel: "Sign Out from AWS"
            )
        case .gcp:
            let account = [profile.roleName, profile.accountID].first {
                $0.contains("@")
            }
            guard let account else { return nil }
            return ProviderSignOutConfirmation(
                profile: profile,
                title: "Revoke GCP account?",
                warning: "This revokes \(account) for GCP configuration \(profile.name) and may affect other configurations sharing that account.",
                confirmLabel: "Revoke GCP Account"
            )
        case .azure:
            let target = profile.accountID.isEmpty
                ? profile.name
                : "\(profile.name) (subscription \(profile.accountID))"
            return ProviderSignOutConfirmation(
                profile: profile,
                title: "Sign out from Azure?",
                warning: "Azure CLI sign-out for \(target) affects the Azure CLI account cache globally.",
                confirmLabel: "Sign Out from Azure"
            )
        case .kubernetes:
            return nil
        }
    }
}
