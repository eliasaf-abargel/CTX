import CTXCore
import AppKit
import SwiftUI

struct ClusterExportsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var exportStatus: (message: String, isError: Bool)?
    @State private var selectedSections: Set<ClusterWorkspaceSection> = []
    @State private var isSelectionMode = false
    @State private var exportFormat: ExportFormat = .json
    @State private var exportStructure: ExportStructure = .separate
    @State private var showExportOptions = false

    private var loadedSections: [(section: ClusterWorkspaceSection, list: KubernetesResourceList)] {
        ClusterWorkspaceSection.allCases.compactMap { section in
            guard section.resourceKind != nil, let list = viewModel.resourceList(for: section), list.status == .reachable else { return nil }
            return (section, list)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow

            if let exportStatus {
                CTXGlassPanel(padding: 14) {
                    Label(exportStatus.message, systemImage: exportStatus.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(exportStatus.isError ? .orange : .green)
                }
            }

            if isSelectionMode && !loadedSections.isEmpty {
                bulkActionPanel
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

    private var headerRow: some View {
        HStack(alignment: .top) {
            CTXSectionHeader(title: "Exports", subtitle: "Export loaded inspection data to a local file. Nothing is sent anywhere.")
            
            Spacer()
            
            if !loadedSections.isEmpty {
                Button(isSelectionMode ? "Cancel" : "Bulk Export") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            selectedSections.removeAll()
                        }
                    }
                }
                .buttonStyle(CTXSecondaryButton())
            }
        }
    }

    private var bulkActionPanel: some View {
        CTXGlassPanel(padding: 12) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(selectedSections.isEmpty ? Color.secondary : Color.blue)
                        .frame(width: 8, height: 8)
                    Text("\(selectedSections.count) / \(loadedSections.count) selected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                HStack(spacing: 12) {
                    let allSelected = selectedSections.count == loadedSections.count
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            selectedSections.removeAll()
                        } else {
                            selectedSections = Set(loadedSections.map(\.section))
                        }
                    }
                    .buttonStyle(CTXSecondaryButton())

                    Button {
                        showExportOptions = true
                    } label: {
                        Label("Export Selected...", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(CTXPrimaryButton())
                    .disabled(selectedSections.isEmpty)
                    .popover(isPresented: $showExportOptions, arrowEdge: .bottom) {
                        exportOptionsPopover
                    }
                }
            }
        }
    }

    private var exportOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Options")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Structure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $exportStructure) {
                    Text("Separate Files").tag(ExportStructure.separate)
                    Text("Combined File").tag(ExportStructure.combined)
                }
                .pickerStyle(.segmented)
                .onChange(of: exportStructure) { _, newStructure in
                    if newStructure == .combined && exportFormat == .csv {
                        exportFormat = .html
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Format")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $exportFormat) {
                    if exportStructure == .separate {
                        Text("JSON").tag(ExportFormat.json)
                        Text("CSV").tag(ExportFormat.csv)
                    } else {
                        Text("HTML Report").tag(ExportFormat.html)
                        Text("JSON").tag(ExportFormat.json)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()
                .padding(.vertical, 4)

            Button {
                showExportOptions = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    bulkExport()
                }
            } label: {
                Text(exportStructure == .separate ? "Export to Folder..." : "Export File...")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CTXPrimaryButton())
        }
        .padding(16)
        .frame(width: 250)
    }

    private func exportRow(_ section: ClusterWorkspaceSection, _ list: KubernetesResourceList) -> some View {
        CTXGlassPanel(padding: 14) {
            HStack(spacing: 12) {
                if isSelectionMode {
                    CTXCheckbox(checked: selectedSections.contains(section)) {
                        if selectedSections.contains(section) {
                            selectedSections.remove(section)
                        } else {
                            selectedSections.insert(section)
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .padding(.trailing, 4)
                }

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

                HStack(spacing: 8) {
                    CTXIconActionButton(title: "Export JSON", systemImage: "doc.text", tint: .blue) {
                        exportSingle(section, list, format: .json)
                    }
                    CTXIconActionButton(title: "Export CSV", systemImage: "tablecells", tint: .green) {
                        exportSingle(section, list, format: .csv)
                    }
                }
            }
        }
    }

    private enum ExportFormat: String, CaseIterable, Identifiable {
        case json = "JSON"
        case csv = "CSV"
        case html = "HTML Report"

        var id: String { self.rawValue }
    }

    private enum ExportStructure: String, CaseIterable, Identifiable {
        case separate = "Separate"
        case combined = "Combined"

        var id: String { self.rawValue }
    }

    private func exportSingle(_ section: ClusterWorkspaceSection, _ list: KubernetesResourceList, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(section.rawValue.lowercased())-\(list.loadedAt.formatted(.iso8601))"
            .replacingOccurrences(of: ":", with: "-")
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
        case .html:
            panel.allowedContentTypes = [.html]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data: Data
            switch format {
            case .json: data = try ResourceExportFormatter.jsonSingle(list)
            case .csv: data = ResourceExportFormatter.csv(list)
            case .html: data = ResourceExportFormatter.html([section: list])
            }
            try data.write(to: url, options: .atomic)
            showStatus(message: "Saved: \(url.lastPathComponent) to \(url.deletingLastPathComponent().path)", isError: false)
        } catch {
            showStatus(message: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func bulkExport() {
        if exportStructure == .separate {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Save Files Here"
            panel.title = "Choose Folder to Save Exports"

            guard panel.runModal() == .OK, let folderURL = panel.url else { return }

            var successCount = 0
            var failedSections: [String] = []

            for section in selectedSections {
                guard let list = viewModel.resourceList(for: section), list.status == .reachable else { continue }
                let ext = exportFormat == .json ? "json" : "csv"
                let fileName = "\(section.rawValue.lowercased()).\(ext)"
                let fileURL = folderURL.appendingPathComponent(fileName)

                do {
                    let data: Data
                    switch exportFormat {
                    case .json: data = try ResourceExportFormatter.jsonSingle(list)
                    case .csv: data = ResourceExportFormatter.csv(list)
                    case .html: data = Data()
                    }
                    try data.write(to: fileURL, options: .atomic)
                    successCount += 1
                } catch {
                    failedSections.append("\(section.rawValue): \(error.localizedDescription)")
                }
            }

            if !failedSections.isEmpty {
                showStatus(message: "Exported \(successCount) files to \(folderURL.path). Failed for: \(failedSections.joined(separator: ", "))", isError: true)
            } else {
                showStatus(message: "Successfully exported \(successCount) files to: \(folderURL.path)", isError: false)
                exitSelectionMode()
            }
        } else {
            // Combined single file
            let panel = NSSavePanel()
            let ext = exportFormat == .json ? "json" : "html"
            panel.nameFieldStringValue = "k8s-export-\(Date().formatted(.iso8601)).\(ext)"
                .replacingOccurrences(of: ":", with: "-")
            panel.allowedContentTypes = exportFormat == .json ? [.json] : [.html]

            guard panel.runModal() == .OK, let fileURL = panel.url else { return }

            var selectedLists: [ClusterWorkspaceSection: KubernetesResourceList] = [:]
            for section in selectedSections {
                if let list = viewModel.resourceList(for: section), list.status == .reachable {
                    selectedLists[section] = list
                }
            }

            do {
                let data: Data
                switch exportFormat {
                case .json: data = try ResourceExportFormatter.jsonCombined(selectedLists)
                case .html: data = ResourceExportFormatter.html(selectedLists)
                case .csv: data = Data()
                }
                try data.write(to: fileURL, options: .atomic)
                showStatus(message: "Successfully saved combined export: \(fileURL.lastPathComponent) to \(fileURL.deletingLastPathComponent().path)", isError: false)
                exitSelectionMode()
            } catch {
                showStatus(message: "Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func showStatus(message: String, isError: Bool) {
        let status = (message: message, isError: isError)
        exportStatus = status

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.exportStatus?.message == status.message {
                withAnimation {
                    self.exportStatus = nil
                }
            }
        }
    }

    private func exitSelectionMode() {
        withAnimation {
            isSelectionMode = false
            selectedSections.removeAll()
        }
    }
}

struct CTXCheckbox: View {
    let checked: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(checked ? Color.blue : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.15 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

enum ResourceExportFormatter {
    static func jsonSingle(_ list: KubernetesResourceList) throws -> Data {
        let rows = list.rows.map { row in row.cells.merging(["id": row.id]) { existing, _ in existing } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    static func jsonCombined(_ lists: [ClusterWorkspaceSection: KubernetesResourceList]) throws -> Data {
        var combinedDict: [String: [[String: String]]] = [:]
        for (section, list) in lists {
            let rows = list.rows.map { row in row.cells.merging(["id": row.id]) { existing, _ in existing } }
            combinedDict[section.rawValue.lowercased()] = rows
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(combinedDict)
    }

    static func csv(_ list: KubernetesResourceList) -> Data {
        var lines = [list.columns.map(escape).joined(separator: ",")]
        for row in list.rows {
            lines.append(list.columns.map { escape(row.cells[$0] ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    static func html(_ lists: [ClusterWorkspaceSection: KubernetesResourceList]) -> Data {
        let sortedLists = lists.sorted { $0.key.rawValue < $1.key.rawValue }
        
        var tabButtonsHTML = ""
        var tabContentsHTML = ""
        
        for (index, pair) in sortedLists.enumerated() {
            let section = pair.key
            let list = pair.value
            let activeClass = index == 0 ? "active" : ""
            
            tabButtonsHTML += """
            <button class="tab-btn \(activeClass)" onclick="showTab(event, '\(section.rawValue)')">
                \(section.rawValue) (\(list.rows.count))
            </button>
            """
            
            var tableRowsHTML = ""
            var headerCellsHTML = ""
            for col in list.columns {
                headerCellsHTML += "<th>\(col)</th>"
            }
            
            for row in list.rows {
                var rowCellsHTML = ""
                for col in list.columns {
                    let cellVal = row.cells[col] ?? ""
                    rowCellsHTML += "<td>\(cellVal)</td>"
                }
                tableRowsHTML += "<tr>\(rowCellsHTML)</tr>"
            }
            
            tabContentsHTML += """
            <div id="tab-\(section.rawValue)" class="tab-content \(activeClass)">
                <h2>\(section.rawValue)</h2>
                <p class="meta">Total items: \(list.rows.count) · Exported from CTX</p>
                <div style="overflow-x: auto;">
                    <table>
                        <thead>
                            <tr>\(headerCellsHTML)</tr>
                        </thead>
                        <tbody>
                            \(tableRowsHTML)
                        </tbody>
                    </table>
                </div>
            </div>
            """
        }
        
        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>CTX Kubernetes Export Report</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background-color: #121212;
                    color: #e0e0e0;
                    margin: 0;
                    padding: 24px;
                }
                .container {
                    max-width: 1200px;
                    margin: 0 auto;
                    background: #1e1e1e;
                    border-radius: 12px;
                    padding: 24px;
                    box-shadow: 0 8px 32px rgba(0,0,0,0.5);
                    border: 1px solid #2d2d2d;
                }
                h1 {
                    font-size: 22px;
                    font-weight: 700;
                    margin-top: 0;
                    margin-bottom: 4px;
                    color: #ffffff;
                }
                .subtitle {
                    font-size: 13px;
                    color: #888888;
                    margin-bottom: 24px;
                }
                .tabs-header {
                    display: flex;
                    gap: 8px;
                    border-bottom: 1px solid #2d2d2d;
                    padding-bottom: 8px;
                    margin-bottom: 24px;
                    overflow-x: auto;
                }
                .tab-btn {
                    background: none;
                    border: none;
                    color: #888888;
                    padding: 8px 16px;
                    font-size: 13px;
                    font-weight: 600;
                    cursor: pointer;
                    border-radius: 6px;
                    transition: all 0.15s ease;
                }
                .tab-btn:hover {
                    background: rgba(255,255,255,0.04);
                    color: #ffffff;
                }
                .tab-btn.active {
                    background: #007aff;
                    color: #ffffff;
                }
                .tab-content {
                    display: none;
                }
                .tab-content.active {
                    display: block;
                }
                h2 {
                    font-size: 18px;
                    margin-top: 0;
                    color: #ffffff;
                }
                .meta {
                    font-size: 12px;
                    color: #888888;
                    margin-bottom: 16px;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 12px;
                }
                th, td {
                    padding: 10px 12px;
                    text-align: left;
                    border-bottom: 1px solid #2d2d2d;
                }
                th {
                    background-color: #262626;
                    color: #ffffff;
                    font-weight: 600;
                }
                tr:hover td {
                    background-color: rgba(255,255,255,0.02);
                }
            </style>
            <script>
                function showTab(event, sectionName) {
                    var contents = document.getElementsByClassName('tab-content');
                    for (var i = 0; i < contents.length; i++) {
                        contents[i].classList.remove('active');
                    }
                    var buttons = document.getElementsByClassName('tab-btn');
                    for (var i = 0; i < buttons.length; i++) {
                        buttons[i].classList.remove('active');
                    }
                    document.getElementById('tab-' + sectionName).classList.add('active');
                    event.currentTarget.classList.add('active');
                }
            </script>
        </head>
        <body>
            <div class="container">
                <h1>CTX Kubernetes Cluster Export Report</h1>
                <div class="subtitle">Generated dynamically from active cluster context</div>
                <div class="tabs-header">
                    \(tabButtonsHTML)
                </div>
                \(tabContentsHTML)
            </div>
        </body>
        </html>
        """
        return htmlString.data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
