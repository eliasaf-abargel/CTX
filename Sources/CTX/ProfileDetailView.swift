import CTXCore
import SwiftUI

struct ProfileDetailView: View {
    let profile: CloudProfile
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) var openWindow
    @Environment(\.colorScheme) var colorScheme
    @State var copiedField: String?
    @State var deleteCandidate: CloudProfile?
    @State var roleUpdateError = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                headerSection
                connectionIssueSection
                sessionSection
                accountSection
                diagnosticsSection
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(32)
        }
        .deleteProfileAlert(store: store, candidate: $deleteCandidate)
        .scrollContentBackground(.hidden)
        .task(id: profile.id) {
            await store.loadAvailableAWSRoles(for: profile)
        }
    }

    var availableRoles: [String] {
        store.availableAWSRoles[profile.id] ?? []
    }
}
