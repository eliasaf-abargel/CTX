import SwiftUI

extension ProfileDetailView {
    var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DIAGNOSTICS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(sectionHeaderStyle)
                .tracking(1.1)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                HStack {
                    Text("Last Login")
                        .foregroundStyle(fieldLabelStyle)
                    Spacer()
                    Text(formatted(store.lastLoginAt))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 38)

                Divider()
                    .padding(.leading, 16)

                HStack {
                    Text("Last Verification")
                        .foregroundStyle(fieldLabelStyle)
                    Spacer()
                    Text(formatted(store.lastVerifiedAt))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 38)

                Divider()
                    .padding(.leading, 16)

                HStack {
                    Text("Last Call Duration")
                        .foregroundStyle(fieldLabelStyle)
                    Spacer()
                    Text(duration(store.lastCommandDuration))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
            }
            .ctxGlassCard()
        }
    }
}
