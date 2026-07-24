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
