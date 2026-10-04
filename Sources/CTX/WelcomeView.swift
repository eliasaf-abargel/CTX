import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            CTXAppLogoView(size: 76)

            Text("Welcome to CTX")
                .font(.title2.weight(.bold))

            SettingsLink {
                Label("Review local configuration", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}
