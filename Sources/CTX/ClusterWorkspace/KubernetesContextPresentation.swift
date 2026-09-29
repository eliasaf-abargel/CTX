import CTXCore
import SwiftUI

extension EnvironmentType {
    var label: String {
        switch self {
        case .production: "Production"
        case .staging: "Staging"
        case .development: "Development"
        case .admin: "Admin"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .production: .red
        case .staging: .orange
        case .development: .blue
        case .admin: .purple
        case .unknown: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .production: "lock.fill"
        case .staging: "clock.badge"
        case .development: "hammer.fill"
        case .admin: "person.badge.key.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension KubernetesProviderType {
    var label: String {
        switch self {
        case .eks: "EKS"
        case .gke: "GKE"
        case .aks: "AKS"
        case .local: "Local"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .eks: .orange
        case .gke: .blue
        case .aks: .cyan
        case .local: .green
        case .unknown: .secondary
        }
    }
}

extension DiagnosticSeverity {
    var tint: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

/// The rule-category pill shown next to a diagnostic finding — one
/// implementation shared by the inspector's Diagnostics tab and the Issues
/// screen, instead of two copies that quietly drift the day only one of them
/// gets updated for a new category.
struct DiagnosticCategoryBadge: View {
    let category: DiagnosticCategory

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.systemImage)
                .font(.system(size: 9))
            Text(category.rawValue)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}
