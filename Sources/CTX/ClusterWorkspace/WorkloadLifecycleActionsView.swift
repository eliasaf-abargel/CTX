import CTXCore
import SwiftUI

/// Restart / Stop-Start / Rollback for a single Deployment, StatefulSet, or
/// DaemonSet — shown at the top of that resource's Overview tab. Every
/// action is a single, well-known `kubectl` verb (`rollout restart`,
/// `scale`, `rollout undo`), never a raw patch, and every action requires an
/// explicit confirmation naming the exact resource — and, when a GitOps
/// controller already owns it, the fact that it may revert the action.
struct WorkloadLifecycleActionsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection
    let controllerKind: KubernetesWorkloadControllerKind

    @State private var pendingAction: PendingLifecycleAction?

    private enum PendingLifecycleAction: Equatable {
        case restart
        case stop
        case start
        case rollback
    }

    private var isStopped: Bool {
        viewModel.stoppedReplicaCounts[selection.row.id] != nil
    }

    /// Read from the same Workloads list the table renders — refreshed by
    /// the view model's own rollout watch after an action, so this counts up
    /// live without a second status reader.
    private var readyCounts: (ready: Int, desired: Int)? {
        guard let ready = viewModel.resourceList(for: .workloads)?.rows.first(where: { $0.id == selection.row.id })?.cells["Ready"] else { return nil }
        let parts = ready.split(separator: "/")
        guard parts.count == 2, let r = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        return (r, d)
    }

    private var isRolling: Bool {
        guard let counts = readyCounts else { return false }
        return counts.ready != counts.desired
    }

    private var isBusy: Bool {
        viewModel.isPerformingLifecycleAction || isRolling
    }

    private var rollbackDisabledReason: String? {
        guard let preflight = viewModel.lifecyclePreflight else { return "Loading revision history…" }
        guard preflight.revisions.count >= 2 else { return "No earlier revision to roll back to." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("LIFECYCLE")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                if let counts = readyCounts, isBusy {
                    CTXStatusDot(tint: counts.ready == counts.desired ? .green : .orange, isPulsing: counts.ready != counts.desired)
                    Text("\(counts.ready)/\(counts.desired) ready")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            gitOpsWarning

            HStack(spacing: 6) {
                actionChip("Restart", icon: "arrow.clockwise", tint: .blue, action: .restart)

                if controllerKind.supportsScale {
                    if isStopped {
                        actionChip("Start", icon: "play.fill", tint: .green, action: .start)
                    } else {
                        actionChip("Stop", icon: "stop.fill", tint: .orange, action: .stop)
                    }
                }

                actionChip("Rollback", icon: "arrow.uturn.backward", tint: .purple, action: .rollback, disabledReason: rollbackDisabledReason)
            }

            if let result = viewModel.lifecycleActionResult {
                CTXOutcomeBanner(result: result) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.lifecycleActionResult = nil
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.96).combined(with: .opacity).combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
        }
        .task(id: selection.row.id) {
            viewModel.loadLifecyclePreflight(selection)
        }
        .alert(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button(confirmButtonTitle(for: action), role: .destructive) {
                perform(action)
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(confirmationMessage(for: action))
        }
    }

    @ViewBuilder
    private var gitOpsWarning: some View {
        if let ownership = viewModel.lifecyclePreflight?.gitOpsOwnership {
            let matchedApp = viewModel.matchingGitOpsApplication(for: ownership.applicationName)
            let webURL = matchedApp.flatMap { GitRepositoryURLHelper.webURL(from: $0.repoURL, revision: $0.targetRevision) }

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.indigo)
                Text(gitOpsSummary(ownership))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if let webURL {
                    Button {
                        NSWorkspace.shared.open(webURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Open Repo")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Open GitOps repository in browser (\(webURL.absoluteString))")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func gitOpsSummary(_ ownership: KubernetesGitOpsOwnership) -> String {
        let app = ownership.applicationName.map { " (\($0))" } ?? ""
        return "Managed by \(ownership.controller)\(app) — may revert this on next sync."
    }

    private func actionChip(_ title: String, icon: String, tint: Color, action: PendingLifecycleAction, disabledReason: String? = nil) -> some View {
        WorkloadActionAnimatedButton(
            title: title,
            icon: icon,
            tint: tint,
            isDisabled: isBusy || disabledReason != nil,
            disabledReason: disabledReason
        ) {
            pendingAction = action
        }
    }

    private var target: String {
        "\(controllerKind.rawValue)/\(selection.row.name) in \(selection.row.namespace ?? "cluster scope")"
    }

    private var gitOpsNote: String {
        guard let ownership = viewModel.lifecyclePreflight?.gitOpsOwnership else { return "" }
        return " \(gitOpsSummary(ownership))"
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .restart: "Restart \(selection.row.name)?"
        case .stop: "Stop \(selection.row.name)?"
        case .start: "Start \(selection.row.name)?"
        case .rollback: "Roll back \(selection.row.name)?"
        case .none: ""
        }
    }

    private func confirmButtonTitle(for action: PendingLifecycleAction) -> String {
        switch action {
        case .restart: "Restart"
        case .stop: "Stop"
        case .start: "Start"
        case .rollback: "Rollback"
        }
    }

    private func confirmationMessage(for action: PendingLifecycleAction) -> String {
        switch action {
        case .restart:
            "Runs a rolling restart of every pod behind \(target).\(gitOpsNote)"
        case .stop:
            "Scales \(target) to 0 replicas — it stops serving traffic until started again.\(gitOpsNote)"
        case .start:
            "Scales \(target) back to \(viewModel.stoppedReplicaCounts[selection.row.id] ?? 1) replicas.\(gitOpsNote)"
        case .rollback:
            "\(rollbackMessage)\(gitOpsNote)"
        }
    }

    /// The honest version of "roll back to the previous revision": the real
    /// revision numbers involved and, where resolvable, the image each one
    /// actually runs — not a claim about what will happen without the data
    /// to back it up.
    private var rollbackMessage: String {
        let revisions = (viewModel.lifecyclePreflight?.revisions ?? []).sorted { $0.revision < $1.revision }
        guard revisions.count >= 2 else {
            return "Rolls \(target) back to its previous revision."
        }
        let from = revisions[revisions.count - 1]
        let to = revisions[revisions.count - 2]
        guard let fromImage = from.image, let toImage = to.image else {
            return "Rolls \(target) back from revision \(from.revision) to revision \(to.revision)."
        }
        if fromImage == toImage {
            return "Rolls \(target) back from revision \(from.revision) to revision \(to.revision) — same image (\(toImage)); likely a config-only change."
        }
        return "Rolls \(target) back from revision \(from.revision) (\(fromImage)) to revision \(to.revision) (\(toImage))."
    }

    private func perform(_ action: PendingLifecycleAction) {
        switch action {
        case .restart: viewModel.restartWorkload(selection)
        case .stop: viewModel.stopWorkload(selection)
        case .start: viewModel.startWorkload(selection)
        case .rollback: viewModel.rollbackWorkload(selection)
        }
    }
}

private struct WorkloadActionAnimatedButton: View {
    let title: String
    let icon: String
    let tint: Color
    var isDisabled: Bool = false
    var disabledReason: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var spinAngle: Double = 0

    var body: some View {
        Button {
            if icon.contains("clockwise") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    spinAngle += 360
                }
            }
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(spinAngle))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isDisabled ? tint.opacity(0.4) : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                tint.opacity(isDisabled ? 0.05 : (isHovered ? 0.20 : 0.12)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(isDisabled ? 0.15 : (isHovered ? 0.5 : 0.28)), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .scaleEffect(isPressed ? 0.94 : (isHovered && !isDisabled ? 1.04 : 1.0))
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        .onHover { hovering in
            isHovered = hovering
            if hovering && !isDisabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(disabledReason ?? title)
    }
}
