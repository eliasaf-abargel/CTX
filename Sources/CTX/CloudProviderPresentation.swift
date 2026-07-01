import CTXCore
import SwiftUI

extension CloudProvider {
    var shortName: String {
        switch self {
        case .aws: "AWS"
        case .gcp: "GCP"
        case .azure: "Azure"
        case .kubernetes: "Kubernetes"
        }
    }

    var compactName: String {
        switch self {
        case .kubernetes: "K8s"
        default: rawValue
        }
    }

    var tint: Color {
        switch self {
        case .aws: .orange
        case .gcp: .blue
        case .azure: .cyan
        case .kubernetes: .indigo
        }
    }
}

extension CloudProfile {
    var contextSubtitle: String {
        let first = region.isEmpty ? fallbackRegion : region
        let second = accountID.isEmpty ? roleName : accountID
        return [first, second]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var fallbackRegion: String {
        switch provider {
        case .kubernetes: "default"
        default: ""
        }
    }
}
