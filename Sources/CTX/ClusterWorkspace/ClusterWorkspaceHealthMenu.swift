import CTXCore
import SwiftUI

struct ClusterWorkspaceHealthMenu: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private var hasDeniedRBAC: Bool {
        viewModel.overviewSummary.rbac.contains { $0.allowed == false }
    }

    private var isChecking: Bool {
        viewModel.isRefreshingOverview
    }

    /// green = healthy, yellow = degraded/checking, red = error/unavailable, gray = unknown/disconnected.
    private var tint: Color {
        if isChecking { return .yellow }
        switch viewModel.overviewSummary.apiStatus {
        case .notChecked:
            return .gray
        case .reachable:
            return hasDeniedRBAC ? .yellow : .green
        default:
            return viewModel.connectionStatusTint == .orange ? .yellow : .red
        }
    }

    private var title: String {
        if isChecking { return "Checking" }
        if viewModel.overviewSummary.apiStatus == .reachable && !hasDeniedRBAC { return "Healthy" }
        if viewModel.overviewSummary.apiStatus == .reachable { return "Limited" }
        return viewModel.connectionStatusTitle
    }

    var body: some View {
        Menu {
            Label(viewModel.connectionStatusTitle, systemImage: "antenna.radiowaves.left.and.right")
            Label(viewModel.rbacStatusTitle, systemImage: "lock.shield")
            ForEach(viewModel.overviewSummary.rbac, id: \.resource) { permission in
                Label("\(permission.resource): \(permissionLabel(permission))", systemImage: permission.allowed == true ? "checkmark.circle" : "minus.circle")
            }
            Divider()
            Text("Last refresh: \(viewModel.lastRefreshedText)")
            if let issue = viewModel.lastRefreshIssue {
                Text(issue.category.presentationSummary)
            }
            Divider()
            Button {
                viewModel.refreshOverview()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            CTXStatusDot(tint: tint, isPulsing: isChecking)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(title) · \(viewModel.rbacStatusTitle) · last refresh \(viewModel.lastRefreshedText)")
    }

    private func permissionLabel(_ permission: KubernetesPermissionSummary) -> String {
        switch permission.allowed {
        case .some(true): "Allowed"
        case .some(false): "Denied"
        case .none: permission.status.cardValue
        }
    }
}
