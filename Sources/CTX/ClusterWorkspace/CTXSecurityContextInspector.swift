import CTXCore
import SwiftUI


public struct CTXSecurityContextInspector: View {
    let audit: SecurityContextAudit

    public init(audit: SecurityContextAudit) {
        self.audit = audit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SECURITY CONTEXT & PRIVILEGES")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                badge(
                    title: audit.isRoot ? "Root (UID 0)" : "UID \(audit.runAsUser)",
                    icon: audit.isRoot ? "exclamationmark.shield" : "shield.checkmark",
                    tint: audit.isRoot ? .red : .green
                )

                badge(
                    title: audit.isReadOnlyRootFS ? "ReadOnly FS" : "Writable FS",
                    icon: audit.isReadOnlyRootFS ? "lock.doc" : "pencil.circle",
                    tint: audit.isReadOnlyRootFS ? .green : .orange
                )

                if audit.isPrivileged {
                    badge(
                        title: "Privileged",
                        icon: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                } else {
                    badge(
                        title: "Unprivileged",
                        icon: "checkmark.shield",
                        tint: .blue
                    )
                }
            }
        }
    }

    private func badge(title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
