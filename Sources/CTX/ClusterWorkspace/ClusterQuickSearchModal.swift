import CTXCore
import SwiftUI

struct ClusterQuickSearchModal: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0

    private var matchingResults: [(section: ClusterWorkspaceSection, row: KubernetesResourceRow)] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lower = query.lowercased()
        var results: [(section: ClusterWorkspaceSection, row: KubernetesResourceRow)] = []
        for section in ClusterWorkspaceSection.allCases {
            guard let list = viewModel.resourceList(for: section) else { continue }
            for row in list.rows {
                if row.name.lowercased().contains(lower) || (row.namespace?.lowercased().contains(lower) ?? false) {
                    results.append((section: section, row: row))
                    if results.count >= 25 { break }
                }
            }
            if results.count >= 25 { break }
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)

                TextField("Search all cluster resources (⌘K)...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }

                Button("Esc") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(white: 0.16))

            Divider()

            if matchingResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: query.isEmpty ? "command" : "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Type to search across all resources" : "No matching resources found")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if query.isEmpty {
                        VStack(spacing: 8) {
                            Text("QUICK FAVORITE FILTERS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button("🛑 CrashLoopBackOff") { query = "crash" }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.red.opacity(0.12), in: Capsule())

                                Button("⚠️ Warning Events") { query = "warning" }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.12), in: Capsule())

                                Button("⚡ High CPU") { query = "cpu" }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.cyan.opacity(0.12), in: Capsule())
                            }
                            .font(.caption.weight(.medium))
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matchingResults.enumerated()), id: \.element.row.id) { index, item in
                                let isSelected = index == selectedIndex
                                Button {
                                    selectItem(item)
                                } label: {
                                    HStack(spacing: 10) {
                                        TechBrandIconView(name: item.row.name)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.row.name)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.primary)
                                            if let ns = item.row.namespace {
                                                Text(ns).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(item.section.rawValue)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(isSelected ? .white : .secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(isSelected ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? Color.blue.opacity(0.16) : Color.clear, in: Rectangle())
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)

                                Divider().opacity(0.4)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 540, height: 380)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
    }

    private func selectItem(_ item: (section: ClusterWorkspaceSection, row: KubernetesResourceRow)) {
        viewModel.selectResource(item.row, in: item.section)
        dismiss()
    }
}
