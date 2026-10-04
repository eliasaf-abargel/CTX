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
                    .font(.callout)
                    .foregroundStyle(.blue)

                TextField("Search all cluster resources (⌘K)...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
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
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Type to search across all resources" : "No matching resources found")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if query.isEmpty {
                        VStack(spacing: 8) {
                            Text("QUICK FAVORITE FILTERS")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button {
                                    query = "crash"
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "exclamationmark.octagon.fill")
                                            .foregroundStyle(.red)
                                        Text("CrashLoopBackOff")
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.red.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    query = "warning"
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                        Text("Warning Events")
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    query = "cpu"
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "bolt.fill")
                                            .foregroundStyle(.cyan)
                                        Text("High CPU")
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.cyan.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(size: 11.5, weight: .medium))
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
                                                .font(.system(.caption, weight: .semibold))
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
