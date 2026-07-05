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
        case .production: "exclamationmark.triangle.fill"
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
