import SwiftUI

/// The connect/disconnect switch, shared by the sidebar and the menu bar.
///
/// One control in one file so the two surfaces cannot drift apart: a person who learns
/// the switch in the menu bar should find the same thing, behaving the same way, in the
/// main window.
struct MiniSwitch: View {
    @Binding var isOn: Bool
    /// Held during a connect or disconnect. Flipping mid-transition races the operation
    /// already in flight, so the switch shows progress and stops accepting input.
    var isBusy: Bool = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor.opacity(0.88) : Color.secondary.opacity(0.18))
                    .background(.thinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(isOn ? 0.24 : 0.12), lineWidth: 0.5)
                    }
                    .frame(width: 28, height: 16)
                    .shadow(color: (isOn ? Color.accentColor : Color.black).opacity(0.22), radius: 3, y: 1)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.45)
                        .frame(width: 12, height: 12)
                        .padding(2)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .padding(2)
                        .shadow(color: .black.opacity(0.24), radius: 1, y: 0.5)
                }
            }
            .frame(width: 32, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(isBusy ? "Working" : (isOn ? "Disconnect" : "Connect"))
    }
}
