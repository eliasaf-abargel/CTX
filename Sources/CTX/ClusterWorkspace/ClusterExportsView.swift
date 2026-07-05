import CTXCore
import AppKit
import SwiftUI

struct ClusterExportsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var exportError: String?

    private var loadedSections: [(section: ClusterWorkspaceSection, list: KubernetesResourceList)] {
        ClusterWorkspaceSection.allCases.compactMap { section in
            guard section.resourceKind != nil, let list = viewModel.resourceList(for: section), list.status == .reachable else { return nil }
            return (section, list)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CTXSectionHeader(title: "Exports", subtitle: "Export loaded inspection data to a local file. Nothing is sent anywhere.")

            if let exportError {
                CTXGlassPanel(padding: 14) {
                    Label(exportError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if loadedSections.isEmpty {
                CTXGlassPanel {
                    CTXEmptyStateView(
                        title: "Nothing loaded yet",
                        message: "Open Namespaces, Nodes, Pods, or another resource screen first, then come back here to export it.",
                        systemImage: "square.and.arrow.down"
                    )
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(loadedSections, id: \.section) { entry in
                        exportRow(entry.section, entry.list)
                    }
                }
            }
        }
    }

    private func exportRow(_ section: ClusterWorkspaceSection, _ list: KubernetesResourceList) -> some View {
        CTXGlassPanel(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(list.rows.count) items · loaded \(list.loadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Export JSON") { export(section, list, format: .json) }
                    .buttonStyle(CTXSecondaryButton())
                    .controlSize(.small)
                Button("Export CSV") { export(section, list, format: .csv) }
                    .buttonStyle(CTXSecondaryButton())
                    .controlSize(.small)
            }
        }
    }

    private enum ExportFormat { case json, csv }

    private func export(_ section: ClusterWorkspaceSection, _ list: KubernetesResourceList, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(section.rawValue.lowercased())-\(list.loadedAt.formatted(.iso8601))"
            .replacingOccurrences(of: ":", with: "-")
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data: Data
            switch format {
            case .json: data = try ResourceExportFormatter.json(list)
            case .csv: data = ResourceExportFormatter.csv(list)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
}

enum ResourceExportFormatter {
    static func json(_ list: KubernetesResourceList) throws -> Data {
        let rows = list.rows.map { row in row.cells.merging(["id": row.id]) { existing, _ in existing } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    static func csv(_ list: KubernetesResourceList) -> Data {
        var lines = [list.columns.map(escape).joined(separator: ",")]
        for row in list.rows {
            lines.append(list.columns.map { escape(row.cells[$0] ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
