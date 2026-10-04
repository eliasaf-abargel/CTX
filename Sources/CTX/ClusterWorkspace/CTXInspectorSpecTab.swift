import CTXCore
import SwiftUI

/// Dedicated "Spec & Config" tab in the resource inspector.
/// Provides deep runtime inspection for Containers, Health Probes, Security Context,
/// Environment Variables, Service Endpoints, and ConfigMap data without cluttering
/// the high-level Overview tab.
struct CTXInspectorSpecTab: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection
    let detail: KubernetesResourceDetail

    @State private var podSpec: PodSpecInsight?
    @State private var endpoints: [EndpointTarget] = []
    @State private var isLoading = false
    @State private var selectedContainerName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selection.kind {
            case .pods, .workloads:
                workloadSpecContent
            case .services:
                serviceSpecContent
            case .configMaps, .secretMetadata:
                configSpecContent
            default:
                defaultSpecContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: selection.row.id) {
            await loadSpec()
        }
    }

    // MARK: - Workload & Pod Spec Content

    @ViewBuilder
    private var workloadSpecContent: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading container specifications…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)
        } else if let podSpec, podSpec.status == .reachable {
            let containers = podSpec.containers

            if containers.isEmpty {
                Text("No container definitions found in spec.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                // Container Selector (if multi-container)
                if containers.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(containers) { container in
                            let isSelected = (selectedContainerName ?? containers.first?.name) == container.name
                            Button {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                                    selectedContainerName = container.name
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: container.isInitContainer ? "arrow.down.circle" : "shippingbox")
                                        .font(.system(size: 11, weight: .bold))
                                    Text(container.name)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }

                let activeContainer = containers.first(where: { $0.name == (selectedContainerName ?? containers.first?.name) }) ?? containers[0]

                VStack(alignment: .leading, spacing: 16) {
                    // Container Header Info
                    CTXGlassPanel(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: activeContainer.isInitContainer ? "arrow.down.circle.fill" : "shippingbox.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.accentColor)

                                Text(activeContainer.isInitContainer ? "Init Container: \(activeContainer.name)" : "Container: \(activeContainer.name)")
                                    .font(.system(size: 13.5, weight: .bold))

                                Spacer()

                                if !activeContainer.probes.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 10))
                                        Text("\(activeContainer.probes.count) Probes")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundStyle(Color.green)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.12), in: Capsule())
                                }
                            }

                            Divider().opacity(0.3)

                            CTXInspectorFieldRow(label: "Image", value: activeContainer.image, monospaced: true)

                            resourceAllocationRow(activeContainer.resources)
                        }
                    }

                    // Probes
                    if !activeContainer.probes.isEmpty {
                        CTXProbesInspector(probes: activeContainer.probes)
                    }

                    // Security Context
                    CTXSecurityContextInspector(audit: activeContainer.security)

                    // Environment Variables
                    CTXEnvironmentVariablesInspector(items: activeContainer.env)

                    // Pod Service Account & Identity
                    if !podSpec.serviceAccount.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SECURITY IDENTITY & SERVICE ACCOUNT")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.secondary)

                            CTXInspectorFieldRow(label: "Account", value: podSpec.serviceAccount, monospaced: true)
                        }
                    }
                }
            }
        } else if let diagnostic = podSpec?.diagnostic {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(diagnostic.stderrSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func resourceAllocationRow(_ allocation: ResourceAllocation) -> some View {
        let unset = "not set"
        return VStack(alignment: .leading, spacing: 6) {
            CTXInspectorFieldRow(
                label: "CPU",
                value: "Request: \(allocation.cpuRequest ?? unset)  ·  Limit: \(allocation.cpuLimit ?? unset)",
                monospaced: true
            )
            CTXInspectorFieldRow(
                label: "Memory",
                value: "Request: \(allocation.memoryRequest ?? unset)  ·  Limit: \(allocation.memoryLimit ?? unset)",
                monospaced: true
            )
        }
    }

    // MARK: - Service Spec Content

    @ViewBuilder
    private var serviceSpecContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            CTXServiceEndpointsInspector(targets: endpoints)

            // Routing Ports Table
            if let ports = selection.row.cells["Ports"], !ports.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NETWORK PORT MAPPINGS")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        let portEntries = ports.split(separator: ",").map(String.init)
                        ForEach(portEntries, id: \.self) { portEntry in
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.swap")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.accentColor)

                                Text(portEntry.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }

            // Related Backend Pods
            if let matchingPods = backendPods {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("BACKEND PODS (\(matchingPods.count))")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if matchingPods.isEmpty {
                        Text("No active pods matching selector.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(matchingPods.prefix(12)) { pod in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill((pod.cells["Status"] ?? "").lowercased() == "running" ? Color.green : Color.orange)
                                        .frame(width: 6, height: 6)

                                    Text(pod.name)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                                    Spacer()

                                    Text(pod.cells["Status"] ?? "Unknown")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - ConfigMap & Secret Spec Content

    @ViewBuilder
    private var configSpecContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DATA KEYS & CONFIGURATION ENTRIES")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.secondary)

            let keys = (selection.row.cells["Data Keys"] ?? selection.row.cells["Keys"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if keys.isEmpty {
                Text("No data keys defined in this resource.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        HStack(spacing: 8) {
                            Image(systemName: selection.kind == .secretMetadata ? "key.fill" : "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(selection.kind == .secretMetadata ? Color.orange : Color.blue)

                            Text(key)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))

                            Spacer()

                            Button {
                                copyToClipboard(key)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy key name")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var defaultSpecContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPECIFICATION")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.secondary)

            ForEach(detail.sections) { section in
                CTXInspectorSection(title: section.title, fields: section.fields)
            }
        }
    }


    private var backendPods: [KubernetesResourceRow]? {
        let selector = selection.row.cells["Selector"] ?? ""
        guard !selector.isEmpty, let pods = viewModel.resourceList(for: .pods)?.rows else { return nil }
        let parsed = KubernetesRelatedPods.parseSelector(selector)
        return pods.filter { pod in
            guard let podNs = pod.namespace, let rowNs = selection.row.namespace, podNs == rowNs else { return false }
            guard let labels = pod.cells["Labels"] else { return false }
            return parsed.allSatisfy { key, val in labels.contains("\(key)=\(val)") }
        }
    }

    // MARK: - Data Loading

    private func loadSpec() async {
        guard let namespace = selection.row.namespace else { return }
        isLoading = true
        defer { isLoading = false }

        switch selection.kind {
        case .pods:
            podSpec = await viewModel.specReader.podSpec(
                context: viewModel.context,
                namespace: namespace,
                name: selection.row.name
            )
            if let first = podSpec?.containers.first?.name {
                selectedContainerName = first
            }
        case .workloads:
            let resourceKind = viewModel.controllerKind(for: selection.row)?.kubectlResource ?? "deployment"
            podSpec = await viewModel.specReader.workloadSpec(
                context: viewModel.context,
                resourceKind: resourceKind,
                namespace: namespace,
                name: selection.row.name
            )
            if let first = podSpec?.containers.first?.name {
                selectedContainerName = first
            }
        case .services:
            let result = await viewModel.specReader.serviceEndpoints(
                context: viewModel.context,
                namespace: namespace,
                name: selection.row.name
            )
            endpoints = result.targets
        default:
            break
        }
    }
}
