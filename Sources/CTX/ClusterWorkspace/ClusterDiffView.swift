import CTXCore
import SwiftUI

struct ResourceDiffResult {
    struct Change: Identifiable {
        var id: String { row.id }
        let row: KubernetesResourceRow
    }

    let added: [KubernetesResourceRow]
    let removed: [KubernetesResourceRow]
    let changed: [Change]
    let unchangedCount: Int
    let comparedAt: Date

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    static func compare(before: KubernetesResourceList?, after: KubernetesResourceList) -> ResourceDiffResult {
        let beforeRows = before?.rows ?? []
        let beforeByID = Dictionary(uniqueKeysWithValues: beforeRows.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.rows.map { ($0.id, $0) })

        let added = after.rows.filter { beforeByID[$0.id] == nil }
        let removed = beforeRows.filter { afterByID[$0.id] == nil }
        var changed: [ResourceDiffResult.Change] = []
        var unchangedCount = 0
        for row in after.rows {
            guard let previous = beforeByID[row.id] else { continue }
            if previous.cells != row.cells {
                changed.append(.init(row: row))
            } else {
                unchangedCount += 1
            }
        }

        return ResourceDiffResult(added: added, removed: removed, changed: changed, unchangedCount: unchangedCount, comparedAt: Date())
    }
}

struct ClusterDiffView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private var sections: [ClusterWorkspaceSection] {
        ClusterWorkspaceSection.allCases.filter { $0.resourceKind != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CTXSectionHeader(title: "Diff", subtitle: "Compare the last loaded snapshot against a fresh inspection refresh. Nothing is changed on the cluster.")

            VStack(spacing: 10) {
                ForEach(sections) { section in
                    diffRow(section)
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: viewModel.diffingKinds)
    }

    private func diffRow(_ section: ClusterWorkspaceSection) -> some View {
        guard let kind = section.resourceKind else { return AnyView(EmptyView()) }
        let isDiffing = viewModel.diffingKinds.contains(kind)
        let result = viewModel.diffResult(for: kind)

        return AnyView(
            CTXGlassPanel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                            if let result {
                                Text("Compared \(result.comparedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not compared yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if isDiffing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Compare cached vs. live") {
                                viewModel.runDiff(kind: kind)
                            }
                            .buttonStyle(CTXSecondaryButton())
                            .controlSize(.small)
                        }
                    }

                    if let result {
                        diffSummary(result)
                    }
                }
            }
        )
    }

    private func diffSummary(_ result: ResourceDiffResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                diffBadge("+\(result.added.count)", tint: .green)
                diffBadge("-\(result.removed.count)", tint: .red)
                diffBadge("~\(result.changed.count)", tint: .orange)
                Text("\(result.unchangedCount) unchanged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if result.isEmpty {
                Text("No differences since the last load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.added.prefix(20)) { row in
                        diffLine("+ \(row.name)", tint: .green)
                    }
                    ForEach(result.removed.prefix(20)) { row in
                        diffLine("- \(row.name)", tint: .red)
                    }
                    ForEach(result.changed.prefix(20)) { change in
                        diffLine("~ \(change.row.name)", tint: .orange)
                    }
                }
            }
        }
    }

    private func diffBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func diffLine(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
