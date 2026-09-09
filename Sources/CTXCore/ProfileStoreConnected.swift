import Foundation

extension ProfileStore {
    /// Every profile with a live session, not one per provider.
    ///
    /// One sign-in covers every account behind a portal, so several AWS profiles are
    /// commonly connected at once. Listing one per provider hid the rest and made a
    /// second account look disconnected while its credentials were valid.
    public var connectedProfiles: [CloudProfile] {
        profiles
            .filter { $0.status == .connected }
            .sorted { ($0.provider.rawValue, $0.name) < ($1.provider.rawValue, $1.name) }
    }
}
