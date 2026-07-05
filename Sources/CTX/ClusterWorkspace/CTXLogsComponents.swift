import CTXCore
import SwiftUI

/// Shared "logs fetch failed" panel — one implementation for both the standalone
/// Logs screen and the inspector's Logs tab, instead of two near-identical ones.
struct CTXLogsIssuePanel: View {
    let result: KubernetesLogsResult
    let retry: () -> Void

    var body: some View {
        CTXDiagnosticCard(
            systemImage: "exclamationmark.triangle",
            tint: result.status.tint,
            title: "Logs unavailable: \(result.status.cardValue)",
            message: result.status.cardSubtitle,
            diagnosticSummary: result.diagnostic?.safeSummary,
            retry: retry
        )
    }
}

/// Shared pod picker for the Logs screen and the inspector's Logs tab — one
/// implementation so there is exactly one place that decides sort order and row
/// content, not two screens that could quietly drift apart.
///
/// A plain `Picker` can't show more than one line of text per row, which isn't
/// enough to convey status/ready/restarts/age at a glance, so this is a button
/// that opens a popover of custom rows instead.
struct CTXPodPicker: View {
    let pods: [KubernetesResourceRow]
    let selectedPodID: String?
    var showsNamespaceColumn: Bool = false
    let onSelect: (KubernetesResourceRow) -> Void

    @State private var isPresented = false
    @State private var filterQuery = ""

    private var filteredSortedPods: [KubernetesResourceRow] {
        let sorted = PodLogSelection.sortedForPicker(pods)
        guard !filterQuery.isEmpty else { return sorted }
        return sorted.filter { row in
            row.name.localizedCaseInsensitiveContains(filterQuery)
                || (row.namespace ?? "").localizedCaseInsensitiveContains(filterQuery)
                || (row.cells["Workload"] ?? "").localizedCaseInsensitiveContains(filterQuery)
        }
    }

    private var selectedRow: KubernetesResourceRow? {
        pods.first { $0.id == selectedPodID }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusTint(for: selectedRow))
                    .frame(width: 7, height: 7)
                Text(selectedRow.map(title) ?? "Select a pod")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
        .buttonStyle(CTXSecondaryButton())
        .frame(maxWidth: 260)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            podList
        }
        .help("Select a pod to view its logs")
    }

    private var podList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                TextField("Filter pods...", text: $filterQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !filterQuery.isEmpty {
                    Button {
                        filterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredSortedPods) { row in
                        podRow(row)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(row)
                                isPresented = false
                                filterQuery = ""
                            }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 360, height: min(CGFloat(filteredSortedPods.count) * 50 + 44, 380))
    }

    private func podRow(_ row: KubernetesResourceRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusTint(for: row))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(row))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let workload = row.cells["Workload"], !workload.isEmpty {
                        Text(workload)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(detailLine(row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.id == selectedPodID {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(row.id == selectedPodID ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func title(_ row: KubernetesResourceRow) -> String {
        showsNamespaceColumn ? "\(row.namespace ?? "-") / \(row.name)" : row.name
    }

    private func detailLine(_ row: KubernetesResourceRow) -> String {
        [row.cells["Status"], row.cells["Ready"].map { "\($0) ready" }, row.cells["Restarts"].map { "\($0) restarts" }, row.cells["Age"]]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func statusTint(for row: KubernetesResourceRow?) -> Color {
        guard let row else { return .secondary }
        switch PodLogSelection.rank(for: row) {
        case .runningReady: return .green
        case .warning: return .red
        case .pending: return .yellow
        case .completed: return .secondary
        }
    }
}

/// Tail-length selector as CTX chip buttons — not a native `Picker`, which on
/// macOS defaults to a dark dropdown menu that reads as a raw system control
/// dropped into an otherwise custom-styled toolbar. Same capsule/opacity language
/// as `CTXStatusBadge` and the rest of the design system.
struct CTXLogsTailSelector: View {
    let options: [Int]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text("Last \(option)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selection == option ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(selection == option ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Shared controls bar: pod picker, container picker (only when there's more
/// than one), tail selector, Reload, Copy. Used identically by the standalone
/// Logs screen and the inspector's Logs tab.
struct CTXLogsControls: View {
    let pods: [KubernetesResourceRow]
    let selectedPodID: String?
    var showsNamespaceColumn: Bool = false
    let containers: [String]
    let selectedContainer: String?
    let tailLines: Int
    /// The raw log text to copy, or `nil`/empty when there is nothing to copy.
    var copyText: String?
    let isLoading: Bool
    let onSelectPod: (KubernetesResourceRow) -> Void
    let onSelectContainer: (String) -> Void
    let onSelectTail: (Int) -> Void
    let onReload: () -> Void

    private static let tailOptions = [100, 500, 1000]

    var body: some View {
        HStack(spacing: 10) {
            if !pods.isEmpty {
                CTXPodPicker(pods: pods, selectedPodID: selectedPodID, showsNamespaceColumn: showsNamespaceColumn, onSelect: onSelectPod)
            }

            if containers.count > 1 {
                Picker("Container", selection: containerBinding) {
                    ForEach(containers, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            CTXLogsTailSelector(options: Self.tailOptions, selection: tailBinding)

            Spacer(minLength: 8)

            if let text = copyText, !text.isEmpty {
                CTXCopyIconButton(value: text)
            }
            CTXReloadIconButton(action: onReload, isLoading: isLoading)
                .disabled(selectedPodID == nil)
        }
    }

    private var containerBinding: Binding<String> {
        Binding(get: { selectedContainer ?? containers.first ?? "" }, set: onSelectContainer)
    }

    private var tailBinding: Binding<Int> {
        Binding(get: { tailLines }, set: onSelectTail)
    }
}

/// Shared inspection log panel: monospaced, scrollable, optional line-wrap,
/// optional ANSI-escape stripping for readability, subtle timestamp dimming
/// (display only — Copy always uses the untouched raw text), line count, and
/// auto-scroll to the newest line whenever the text changes (reload, tail
/// change, pod/container change).
struct CTXLogsViewer: View {
    let rawText: String
    let tailLines: Int

    @State private var wrapLines = false
    @State private var stripANSI = true

    private static let bottomAnchorID = "ctx-logs-bottom"

    private var displayText: String {
        stripANSI ? Self.strippingANSICodes(from: rawText) : rawText
    }

    private var lineCount: Int {
        rawText.isEmpty ? 0 : rawText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Inspection · last \(tailLines) requested · \(lineCount) lines returned")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle("Wrap", isOn: $wrapLines)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Strip color codes", isOn: $stripANSI)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().opacity(0.55)
            ScrollViewReader { proxy in
                ScrollView(wrapLines ? [.vertical] : [.vertical, .horizontal]) {
                    Text(styledLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .topLeading)
                        .id(Self.bottomAnchorID)
                }
                .onChange(of: rawText) { _, _ in
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .frame(minHeight: 320, maxHeight: .infinity, alignment: .top)
        }
    }

    private var styledLog: AttributedString {
        Self.dimmingLeadingTimestamps(in: displayText)
    }

    static func strippingANSICodes(from text: String) -> String {
        guard text.contains("\u{1B}[") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    static func dimmingLeadingTimestamps(in text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString("") }
        var result = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if let spaceIndex = line.firstIndex(of: " "), looksLikeTimestamp(line[line.startIndex..<spaceIndex]) {
                var timestamp = AttributedString(line[line.startIndex..<spaceIndex])
                timestamp.foregroundColor = .secondary
                result += timestamp
                result += AttributedString(line[spaceIndex...])
            } else {
                result += AttributedString(line)
            }
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private static func looksLikeTimestamp(_ candidate: Substring) -> Bool {
        candidate.count >= 20 && candidate.contains("T") && (candidate.hasSuffix("Z") || candidate.contains("+"))
    }
}
