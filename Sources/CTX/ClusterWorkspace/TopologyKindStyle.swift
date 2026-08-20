import CTXCore
import SwiftUI

extension TopologyGraphNodeKind {
    var topologyTint: Color {
        switch self {
        case .ingress: .orange
        case .service: .blue
        case .workload: .purple
        case .pod, .podGroup, .terminalGroup, .overflow: .teal
        case .pvc: .green
        case .hpa: .pink
        }
    }
}

extension TopologyNodeHealthState {
    var topologyTint: Color {
        if isFailed { return .red }
        if isDegraded { return .orange }
        if isIdle { return .gray }
        return .green
    }
}
