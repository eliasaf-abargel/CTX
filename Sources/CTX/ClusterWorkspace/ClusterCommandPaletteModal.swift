import CTXCore
import SwiftUI

/// Filter category tab in the Command Palette
enum CommandPaletteFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case commands = "Commands"
    case workloads = "Workloads"
    case pods = "Pods"
    case services = "Services"
    case namespaces = "Namespaces"

    var id: String { rawValue }
}

/// An entry in the Command Palette: either an executable command or a cluster resource.
enum CommandPaletteItem: Identifiable {
    case command(id: String, title: String, subtitle: String, icon: String, shortcut: String?, action: () -> Void)
    case resource(section: ClusterWorkspaceSection, row: KubernetesResourceRow)
    case namespace(name: String)

    var id: String {
        switch self {
        case .command(let id, _, _, _, _, _): "cmd:\(id)"
        case .resource(let section, let row): "res:\(section.rawValue):\(row.id)"
        case .namespace(let name): "ns:\(name)"
        }
    }
}

/// Apple-Native Spotlight / Raycast-Style Command Palette (⌘K)
struct ClusterCommandPaletteModal: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedFilter: CommandPaletteFilter = .all
    @State private var selectedIndex: Int = 0
    /// Gates the bare-Space Quick Look shortcut below — Finder's own rule for
    /// Space-opens-Quick-Look is that it only fires when the list has focus,
    /// not a text field, so typing "web frontend" into the search box types a
    /// space instead of toggling Quick Look on the currently-selected row.
    @FocusState private var isSearchFieldFocused: Bool
    /// Recomputed on a debounce while typing, immediately on a filter-pill tap.
    /// The scan below touches every cached row across up to eight resource
    /// kinds — fine once, not fine redone from scratch on every keystroke on a
    /// cluster with a few thousand pods, which is exactly the cluster size this
    /// palette exists for.
    @State private var matchingItems: [CommandPaletteItem] = []

    // List of universal commands
    private var allCommands: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        items.append(.command(
            id: "topology",
            title: "Architecture Map / Topology",
            subtitle: "View visual DAG graph of workloads, services & pods",
            icon: "point.topleft.down.to.point.bottomright.curvepath",
            shortcut: "⌘2",
            action: {
                viewModel.selectedSection = .topology
                dismiss()
            }
        ))

        items.append(.command(
            id: "logs",
            title: "Live Streaming Logs",
            subtitle: "Open real-time container log viewer with regex search",
            icon: "text.alignleft",
            shortcut: "⌘6",
            action: {
                viewModel.selectedSection = .logs
                dismiss()
            }
        ))

        items.append(.command(
            id: "port_forward",
            title: "Port Forwarding Manager",
            subtitle: "Manage active tunnels and forward local ports to services",
            icon: "arrowshape.turn.up.right",
            shortcut: "⌘7",
            action: {
                viewModel.selectedSection = .portForward
                dismiss()
            }
        ))

        items.append(.command(
            id: "troubled",
            title: "Troubled Workloads & Issues",
            subtitle: "Inspect failing pods, crash loops, and diagnostic alerts",
            icon: "exclamationmark.triangle",
            shortcut: "⌘8",
            action: {
                viewModel.selectedSection = .issues
                dismiss()
            }
        ))

        items.append(.command(
            id: "refresh",
            title: "Bypass Cache & Hard Refresh",
            subtitle: "Force fetch the freshest resources from the cluster API",
            icon: "arrow.clockwise",
            shortcut: "⌘R",
            action: {
                viewModel.loadSelectedSection(bypassCache: true)
                dismiss()
            }
        ))

        items.append(.command(
            id: "export",
            title: "Export Resources (YAML / JSON / CSV)",
            subtitle: "Generate formatted manifests and summary exports",
            icon: "square.and.arrow.down",
            shortcut: nil,
            action: {
                viewModel.selectedSection = .exports
                dismiss()
            }
        ))

        items.append(.command(
            id: "copy_context",
            title: "Copy Kube Context Name",
            subtitle: viewModel.context.contextName,
            icon: "doc.on.doc",
            shortcut: nil,
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.context.contextName, forType: .string)
                dismiss()
            }
        ))

        let currentNS = viewModel.selectedNamespace.displayName
        items.append(.command(
            id: "copy_namespace",
            title: "Copy Current Namespace",
            subtitle: currentNS,
            icon: "square.stack.3d.up",
            shortcut: nil,
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentNS, forType: .string)
                dismiss()
            }
        ))

        return items
    }

    private func computeMatchingItems() -> [CommandPaletteItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [CommandPaletteItem] = []

        // 1. Commands
        if selectedFilter == .all || selectedFilter == .commands {
            let filteredCommands = allCommands.filter { item in
                guard case .command(_, let title, let subtitle, _, _, _) = item else { return false }
                if cleanQuery.isEmpty { return true }
                return title.lowercased().contains(cleanQuery) || subtitle.lowercased().contains(cleanQuery)
            }
            results.append(contentsOf: filteredCommands)
        }

        // 2. Namespaces
        if selectedFilter == .all || selectedFilter == .namespaces {
            let namespaces = viewModel.availableNamespaces
            let filteredNS = namespaces.filter { ns in
                if cleanQuery.isEmpty { return selectedFilter == .namespaces }
                return ns.lowercased().contains(cleanQuery)
            }.prefix(10).map { CommandPaletteItem.namespace(name: $0) }
            results.append(contentsOf: filteredNS)
        }

        // 3. Resources (Workloads, Pods, Services, etc.)
        let sectionsToSearch: [ClusterWorkspaceSection]
        switch selectedFilter {
        case .all:
            sectionsToSearch = [.workloads, .pods, .services, .ingress, .nodes, .configMaps, .secrets, .cronjobs]
        case .workloads:
            sectionsToSearch = [.workloads]
        case .pods:
            sectionsToSearch = [.pods]
        case .services:
            sectionsToSearch = [.services, .ingress]
        case .commands, .namespaces:
            sectionsToSearch = []
        }

        if !sectionsToSearch.isEmpty {
            for section in sectionsToSearch {
                guard let list = viewModel.resourceList(for: section) else { continue }
                if cleanQuery.isEmpty {
                    // In empty query, show top troubled or first items
                    for row in list.rows where row.warning && results.count < 30 {
                        results.append(.resource(section: section, row: row))
                    }
                } else {
                    // Precomputed, lowercased haystack per row — the same primitive
                    // `CTXResourceTable`'s own local filter uses — instead of calling
                    // `.lowercased()` and allocating fresh strings for every row on
                    // every keystroke.
                    for row in KubernetesResourceRow.filtered(list.rows, matching: cleanQuery) {
                        results.append(.resource(section: section, row: row))
                        if results.count >= 40 { break }
                    }
                }
                if results.count >= 40 { break }
            }
        }

        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                TextField("Search all resources, commands, namespaces... (⌘K)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, weight: .regular))
                    .focused($isSearchFieldFocused)
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }
                    .onAppear {
                        isSearchFieldFocused = true
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button("Esc") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(VisualEffectBackground(material: .headerView, blendingMode: .behindWindow))

            // Category Filter Pills
            HStack(spacing: 8) {
                ForEach(CommandPaletteFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                        selectedIndex = 0
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: selectedFilter == filter ? .semibold : .regular))
                            .foregroundStyle(selectedFilter == filter ? .white : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selectedFilter == filter ? Color.blue : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.04))

            Divider().opacity(0.5)

            // Results List
            if matchingItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(query.isEmpty ? "Type to search resources, commands, or namespaces" : "No matching items found")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(matchingItems.enumerated()), id: \.element.id) { index, item in
                                let isSelected = index == selectedIndex
                                PaletteItemRow(
                                    item: item,
                                    isSelected: isSelected,
                                    onSelect: {
                                        executeItem(item)
                                    },
                                    onLogs: {
                                        if case .resource(let section, let row) = item {
                                            viewModel.openInspector(for: row, in: section, tab: .logs)
                                            dismiss()
                                        }
                                    },
                                    onYAML: {
                                        if case .resource(let section, let row) = item {
                                            viewModel.openInspector(for: row, in: section, tab: .yaml)
                                            dismiss()
                                        }
                                    },
                                    onQuickLook: {
                                        if case .resource(let section, let row) = item {
                                            viewModel.toggleQuickLook(for: row, in: section)
                                            dismiss()
                                        }
                                    }
                                )
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.5)

            // Footer Shortcut Hints
            HStack(spacing: 14) {
                PaletteFooterHint(key: "↑↓", label: "Navigate")
                PaletteFooterHint(key: "↵", label: "Select")
                PaletteFooterHint(key: "Space", label: "Quick Look")
                PaletteFooterHint(key: "⌘L", label: "Logs")
                PaletteFooterHint(key: "⌘Y", label: "YAML")
                Spacer()
                Text("\(matchingItems.count) results")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(VisualEffectBackground(material: .headerView, blendingMode: .behindWindow))
        }
        .frame(width: 620, height: 460)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            matchingItems = computeMatchingItems()
        }
        // A filter-pill tap is a single discrete action, not a burst of
        // keystrokes — it recomputes right away, same as opening the palette.
        .onChange(of: selectedFilter) { _, _ in
            matchingItems = computeMatchingItems()
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            matchingItems = computeMatchingItems()
        }
        // Hidden keyboard navigation listeners
        .background {
            HStack {
                Button("") {
                    if selectedIndex > 0 { selectedIndex -= 1 }
                }
                .keyboardShortcut(.upArrow, modifiers: [])

                Button("") {
                    if selectedIndex < matchingItems.count - 1 { selectedIndex += 1 }
                }
                .keyboardShortcut(.downArrow, modifiers: [])

                Button("") {
                    if selectedIndex < matchingItems.count {
                        executeItem(matchingItems[selectedIndex])
                    }
                }
                .keyboardShortcut(.defaultAction)

                Button("") {
                    if selectedIndex < matchingItems.count,
                       case .resource(let section, let row) = matchingItems[selectedIndex] {
                        viewModel.openInspector(for: row, in: section, tab: .logs)
                        dismiss()
                    }
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("") {
                    if selectedIndex < matchingItems.count,
                       case .resource(let section, let row) = matchingItems[selectedIndex] {
                        viewModel.openInspector(for: row, in: section, tab: .yaml)
                        dismiss()
                    }
                }
                .keyboardShortcut("y", modifiers: .command)

                Button("") {
                    if selectedIndex < matchingItems.count,
                       case .resource(let section, let row) = matchingItems[selectedIndex] {
                        viewModel.toggleQuickLook(for: row, in: section)
                        dismiss()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isSearchFieldFocused)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func executeItem(_ item: CommandPaletteItem) {
        switch item {
        case .command(_, _, _, _, _, let action):
            action()
        case .resource(let section, let row):
            viewModel.openInspector(for: row, in: section, tab: .overview)
            dismiss()
        case .namespace(let name):
            viewModel.setNamespace(.namespace(name))
            dismiss()
        }
    }
}

private struct PaletteItemRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onLogs: () -> Void
    let onYAML: () -> Void
    let onQuickLook: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                switch item {
                case .command(_, let title, let subtitle, let icon, let shortcut, _):
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(.blue)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let shortcut = shortcut {
                        Text(shortcut)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                case .namespace(let name):
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 15))
                        .foregroundStyle(.purple)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("Switch to namespace")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("NAMESPACE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15), in: Capsule())

                case .resource(let section, let row):
                    let kind = section.resourceKind ?? .workloads
                    TechBrandIconView(name: row.name)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if row.warning {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }

                        if let ns = row.namespace {
                            Text(ns)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if isSelected {
                            HStack(spacing: 4) {
                                Text("Space")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                                Text("Preview")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(kind.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? .white : .blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isSelected ? Color.blue : Color.blue.opacity(0.12), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PaletteFooterHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
