import CTXCore
import SwiftUI

/// Opens a terminal scoped to one profile. Shared by the sidebar and the menu bar so
/// the two rows cannot drift apart in wording, size or behaviour.
///
/// Renders nothing when the provider has no per-shell switch, or when the row is not
/// hovered: a button on every row at rest turns a list of states into a wall of
/// controls.
struct TerminalButton: View {
    let profile: CloudProfile
    let isVisible: Bool
    let action: () -> Void
    @ScaledMetric private var size: CGFloat

    init(profile: CloudProfile, isVisible: Bool, size: CGFloat, action: @escaping () -> Void) {
        self.profile = profile
        self.isVisible = isVisible
        self.action = action
        self._size = ScaledMetric(wrappedValue: size)
    }

    var body: some View {
        if isVisible, TerminalLauncher.canOpenTerminal(for: profile) {
            Button(action: action) {
                Image(systemName: "terminal")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .frame(width: size + 7, height: size + 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a terminal using \(profile.name)")
            .accessibilityLabel("Open a terminal using \(profile.name)")
        }
    }
}
