import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            CTXAppLogoView(size: 80)
            
            VStack(spacing: 8) {
                Text("Welcome to CTX")
                    .font(.title3.weight(.bold))
                Text("CTX uses your existing cloud and Kubernetes configurations on this Mac. Select a profile, then Connect to sign in with its provider.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)
            SettingsLink {
                Label("Review local configuration", systemImage: "gearshape")
            }
            Text("Your macOS user stays the same across cloud accounts. Diagnostics stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}
