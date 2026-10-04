import CTXCore
import SwiftUI

/// Represents one major domain of the CTX experience.
private struct OnboardingFeature: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let bulletPoints: [(icon: String, text: String)]
}

private let onboardingFeatures: [OnboardingFeature] = [
    OnboardingFeature(
        id: 0,
        title: "Unified Cloud & Cluster Hub",
        subtitle: "Connect AWS, GCP, Azure, and local Kubernetes contexts seamlessly. 100% on-device — your credentials and tokens never leave this Mac.",
        systemImage: "cloud.fill",
        tint: .blue,
        bulletPoints: [
            ("arrow.triangle.2.circlepath", "Auto-discovers local kubeconfigs (~/.kube/config) and cloud credentials"),
            ("lock.shield.fill", "Zero cloud telemetry — strictly on-device processing and validation"),
            ("shippingbox.fill", "CLI readiness check with one-click Homebrew dependency assistance")
        ]
    ),
    OnboardingFeature(
        id: 1,
        title: "Real-Time Kubernetes Workspace",
        subtitle: "Explore 12 resource categories with live CPU, Memory, and Disk telemetry gauges, instant filtering, and Finder-like Quick Look.",
        systemImage: "server.rack",
        tint: .cyan,
        bulletPoints: [
            ("chart.bar.fill", "Live CPU & Memory utilization meters updated in real-time"),
            ("space", "Hit Space on any resource row for an instant Quick Look preview"),
            ("line.3.horizontal.decrease.circle", "Instant search and multi-namespace scoping across all workloads")
        ]
    ),
    OnboardingFeature(
        id: 2,
        title: "Spec, Config & Deep Diagnostics",
        subtitle: "Executive summary on Overview, deep runtime configurations in Spec, and continuous health auditing in Diagnostics.",
        systemImage: "slider.horizontal.3",
        tint: .purple,
        bulletPoints: [
            ("square.stack.3d.up", "Zero duplicate clutter: Overview summarizes, Spec inspects runtime details"),
            ("heart.fill", "Container Probes, Security Context (UID, RootFS), and masked env vars"),
            ("stethoscope", "Continuous compliance and configuration audit with actionable advice")
        ]
    ),
    OnboardingFeature(
        id: 3,
        title: "Command Palette & Fast Actions",
        subtitle: "Jump anywhere in milliseconds with ⌘K, inspect live logs, and execute lifecycle actions with Apple-grade micro-animations.",
        systemImage: "command",
        tint: .orange,
        bulletPoints: [
            ("keyboard", "Press ⌘K anywhere to jump across namespaces, pods, and clusters"),
            ("arrow.clockwise", "Interactive lifecycle actions: Restart (360° spin), Scale, and Rollback"),
            ("menubar.arrow.up.rectangle", "Native menu bar companion for background health and quick access")
        ]
    ),
    OnboardingFeature(
        id: 4,
        title: "AI & Model Context Protocol (MCP)",
        subtitle: "Supercharge Cursor, Claude Desktop, and AI agents with direct, safe read/write access to your cluster contexts and logs.",
        systemImage: "cpu.fill",
        tint: .green,
        bulletPoints: [
            ("link", "Exposes ctx_list_contexts, ctx_get_resources, ctx_get_logs, and diagnostics"),
            ("doc.text.magnifyingglass", "AI assistants can retrieve real-time logs and diagnose crash loops"),
            ("checkmark.shield", "Strict mutation gate: AI manifest apply is disabled by default in Settings")
        ]
    )
]

struct OnboardingTourView: View {
    let onFinish: () -> Void

    @State private var activeStepIndex = 0
    @State private var interactivePreviewTab = 0
    @State private var simulatedLogToggled = false
    @State private var simulatedConnectionState = [true, false, false, true]
    @Namespace private var animationNamespace

    private var activeFeature: OnboardingFeature {
        onboardingFeatures[activeStepIndex]
    }

    private var isFirstStep: Bool { activeStepIndex == 0 }
    private var isLastStep: Bool { activeStepIndex == onboardingFeatures.count - 1 }

    var body: some View {
        ZStack {
            // Darkened backdrop
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { }

            // Main Modal Window
            VStack(spacing: 0) {
                modalHeader
                Divider().opacity(0.3)
                modalContent
                Divider().opacity(0.3)
                modalFooter
            }
            .frame(width: 760, height: 530)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.4), radius: 35, y: 15)
        }
    }

    // MARK: - Header

    private var modalHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                CTXAppLogoView(size: 26)
                Text("Welcome to CTX")
                    .font(.system(size: 15, weight: .bold))
                Text("Version 1.0")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Spacer()

            // Step Indicator Badge
            HStack(spacing: 6) {
                Text("Step \(activeStepIndex + 1) of \(onboardingFeatures.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Button {
                onFinish()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Tour (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Main Content Split

    private var modalContent: some View {
        HStack(spacing: 0) {
            // Left Navigation Sidebar
            VStack(alignment: .leading, spacing: 6) {
                Text("EXPERIENCE TOUR")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ForEach(onboardingFeatures) { feature in
                    sidebarStepButton(feature)
                }

                Spacer()

                // Keyboard Hint
                HStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("Use ← → arrows to navigate")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .frame(width: 220)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.3)

            // Right Living Showcase Area
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: activeFeature.systemImage)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(activeFeature.tint)

                        Text(activeFeature.title)
                            .font(.system(size: 17, weight: .bold))
                    }

                    Text(activeFeature.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                // Interactive Living Preview Card
                livingPreviewCard
                    .frame(maxWidth: .infinity, maxHeight: 185)

                // Bullet Points
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(activeFeature.bulletPoints, id: \.text) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: point.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(activeFeature.tint)
                                .frame(width: 16, height: 16)
                                .padding(.top, 1)

                            Text(point.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func sidebarStepButton(_ feature: OnboardingFeature) -> some View {
        let isSelected = activeStepIndex == feature.id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                activeStepIndex = feature.id
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? feature.tint : .secondary)
                    .frame(width: 18)

                Text(feature.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Circle()
                        .fill(feature.tint)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? feature.tint.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dynamic Living Preview Card

    @ViewBuilder
    private var livingPreviewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

            switch activeStepIndex {
            case 0:
                cloudHubPreview
            case 1:
                clusterWorkspacePreview
            case 2:
                specInspectorPreview
            case 3:
                commandPalettePreview
            case 4:
                mcpAssistantPreview
            default:
                EmptyView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 1. Cloud Hub Preview
    private var cloudHubPreview: some View {
        VStack(spacing: 6) {
            let contexts = [
                ("k8s-prod-us-east", "Kubernetes · 1.30", "kubernetes", Color.blue),
                ("eks-frontend-cluster", "AWS EKS · us-east-1", "aws", Color.orange),
                ("gke-analytics-core", "GCP GKE · europe-west1", "gcp", Color.red),
                ("minikube-local", "Local Docker Desktop", "server.rack", Color.green)
            ]

            ForEach(contexts.indices, id: \.self) { idx in
                let ctx = contexts[idx]
                let isConnected = simulatedConnectionState[idx]
                HStack(spacing: 8) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(ctx.0)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        Text(ctx.1)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            simulatedConnectionState[idx].toggle()
                        }
                    } label: {
                        Text(isConnected ? "Connected" : "Connect")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isConnected ? Color.green : Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (isConnected ? Color.green : Color.secondary).opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(10)
    }

    // MARK: 2. Cluster Workspace Preview
    private var clusterWorkspacePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WORKLOADS & PODS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Text("Space")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("Quick Look")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                clusterRow(name: "frontend-prod-64b58f", status: "Running", cpu: "180m", mem: "320Mi", warning: false)
                clusterRow(name: "payment-api-89d81c", status: "Running", cpu: "420m", mem: "1.1Gi", warning: false)
                clusterRow(name: "redis-cache-cluster-0", status: "Ready", cpu: "55m", mem: "256Mi", warning: false)
            }
        }
        .padding(12)
    }

    private func clusterRow(name: String, status: String, cpu: String, mem: String, warning: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(warning ? Color.orange : Color.green)
                .frame(width: 6, height: 6)

            Text(name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 4) {
                Text("CPU \(cpu)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("RAM \(mem)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(status)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 3. Spec & Diagnostics Preview
    private var specInspectorPreview: some View {
        VStack(spacing: 8) {
            // Interactive Tab Switcher
            HStack(spacing: 4) {
                let tabs = ["Overview", "Spec & Config", "Diagnostics", "YAML", "Logs"]
                ForEach(tabs.indices, id: \.self) { idx in
                    let isSel = interactivePreviewTab == idx
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            interactivePreviewTab = idx
                        }
                    } label: {
                        Text(tabs[idx])
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isSel ? Color.white : Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSel ? Color.purple : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Tab Content
            if interactivePreviewTab == 1 {
                // Spec & Config
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill").foregroundStyle(.green).font(.system(size: 10))
                            Text("Liveness & Readiness Probes")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("HTTP /healthz :8080 · delay 10s · period 15s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(.blue).font(.system(size: 10))
                            Text("Security Privileges")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("UID 1000 · Non-Root · ReadOnly RootFS")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } else if interactivePreviewTab == 2 {
                // Diagnostics
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                        Text("All 6 health & reliability checks passed")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Text("No broken selectors, no missing ConfigMap keys, safe limits enforced.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                // Overview
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replicas: 3/3 Ready")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Deployment · 12 pods healthy")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Restart")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(12)
    }

    // MARK: 4. Command Palette Preview
    private var commandPalettePreview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("deploy/frontend-prod")
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text("ESC to dismiss")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.blue)
                    Text("Restart Deployment")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("Rollout restart")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                HStack {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.green)
                    Text("Tail Pod Logs")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("Stream live logs")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(12)
    }

    // MARK: 5. MCP AI Assistant Preview
    private var mcpAssistantPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("MCP Active · 5 Tools Exposed")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12), in: Capsule())

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        simulatedLogToggled.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text(simulatedLogToggled ? "Reset" : "Test ctx_get_logs")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            if simulatedLogToggled {
                VStack(alignment: .leading, spacing: 2) {
                    Text("[AI Query: ctx_get_logs pod=frontend-prod-64b58f]")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("2026-09-29T11:42:01Z [info] HTTP GET /api/v1/healthz 200 OK 2.1ms\n2026-09-29T11:42:04Z [info] Connected to redis-cache:6379 (pool=10)\n2026-09-29T11:42:05Z [info] Readiness probe passed")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    mcpToolPill("ctx_get_resources")
                    mcpToolPill("ctx_get_logs")
                    mcpToolPill("ctx_validate")
                    mcpToolPill("ctx_dry_run")
                }
            }
        }
        .padding(12)
    }

    private func mcpToolPill(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Footer

    private var modalFooter: some View {
        HStack {
            Button("Skip Tour", action: onFinish)
                .font(.system(size: 12.5))
                .buttonStyle(CTXSecondaryButton())

            Spacer()

            // Dots Indicator
            HStack(spacing: 6) {
                ForEach(onboardingFeatures.indices, id: \.self) { idx in
                    Circle()
                        .fill(idx == activeStepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if !isFirstStep {
                    Button("Previous") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            activeStepIndex -= 1
                        }
                    }
                    .font(.system(size: 12.5))
                    .buttonStyle(CTXSecondaryButton())
                }

                Button(isLastStep ? "Launch CTX" : "Next") {
                    if isLastStep {
                        onFinish()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            activeStepIndex += 1
                        }
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .buttonStyle(CTXPrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
