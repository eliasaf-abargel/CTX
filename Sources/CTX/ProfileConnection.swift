import CTXCore
import SwiftUI

extension ProfileStore {
    /// The binding behind the connect switch, wherever it is shown.
    ///
    /// Looks the profile up by id on every read rather than reading the copy passed in.
    /// `CloudProfile` is a value type and SwiftUI keeps a `Binding` across renders, so a
    /// captured copy freezes the status it had when the binding was made - switches
    /// stuck off, and one stuck mid-connect, because the closure never saw the store
    /// change underneath it.
    ///
    /// It reads `status`, not `isActive`: those are different questions, and `isActive`
    /// falls back to a name remembered in defaults, so it stayed true for hours after a
    /// session had expired. Connection is what a switch labelled Connect/Disconnect has
    /// to show.
    ///
    /// Lives here rather than in `ProfileStore` because `CTXCore` deliberately does not
    /// import SwiftUI, and here rather than in each view because two copies of "what the
    /// switch means" is how the menu bar and the main window would come to disagree.
    func connectionBinding(
        for profile: CloudProfile,
        from origin: ProfilePresentationSurface
    ) -> Binding<Bool> {
        let id = profile.id
        return Binding(
            get: { self.profiles.first { $0.id == id }?.status == .connected },
            set: { isOn in
                guard let live = self.profiles.first(where: { $0.id == id }) else { return }
                if isOn {
                    self.login(live, from: origin)
                } else if live.status == .connected {
                    self.logout(live, from: origin)
                }
            }
        )
    }
}
