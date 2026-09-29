import SwiftUI

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
    @State private var fetchPrevious = false
    @State private var selectedContainer = "app"
    @State private var filterQuery = ""
    @State private var fontSize: CGFloat = 11

    private static let bottomAnchorID = "ctx-logs-bottom"

    @State private var cachedFilteredText: String = ""
    /// The rendered form is cached alongside the filtered text. `styledLog` was a
    /// computed property, so the whole `AttributedString` — every line scanned for a
    /// leading timestamp — was rebuilt on each body evaluation, including one per
    /// keystroke in the filter field and every hover anywhere in the window.
    @State private var cachedStyledLog = AttributedString("")

    private func updateCachedFilteredText() {
        let base = stripANSI ? Self.strippingANSICodes(from: rawText) : rawText
        let trimmedQuery = filterQuery.trimmingCharacters(in: .whitespaces)
        if trimmedQuery.isEmpty {
            cachedFilteredText = base
        } else {
            let query = trimmedQuery.lowercased()
            cachedFilteredText = base.components(separatedBy: .newlines)
                .filter { $0.lowercased().contains(query) }
                .joined(separator: "\n")
        }
        cachedStyledLog = Self.dimmingLeadingTimestamps(in: cachedFilteredText)
    }

    private var lineCount: Int {
        cachedFilteredText.isEmpty ? 0 : cachedFilteredText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search logs...", text: $filterQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !filterQuery.isEmpty {
                        Button {
                            filterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Toggle("Previous", isOn: $fetchPrevious)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Toggle("Wrap", isOn: $wrapLines)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Toggle("Strip color", isOn: $stripANSI)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Divider().frame(height: 12)

                    Button {
                        fontSize = max(9, fontSize - 1)
                    } label: {
                        Text("A-").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(fontSize))pt")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.secondary)

                    Button {
                        fontSize = min(16, fontSize + 1)
                    } label: {
                        Text("A+").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.55)
            ScrollViewReader { proxy in
                ScrollView(wrapLines ? [.vertical] : [.vertical, .horizontal]) {
                    Text(styledLog)
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(Self.bottomAnchorID)
                }
                .onChange(of: rawText) { _, _ in
                    updateCachedFilteredText()
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: stripANSI) { _, _ in
                    updateCachedFilteredText()
                }
                .onChange(of: filterQuery) { _, _ in
                    updateCachedFilteredText()
                }
                .onAppear {
                    updateCachedFilteredText()
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .frame(minHeight: 450, maxHeight: .infinity, alignment: .top)
        }
    }

    private var styledLog: AttributedString {
        cachedStyledLog
    }

    static func strippingANSICodes(from text: String) -> String {
        guard text.contains("\u{1B}[") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    static func dimmingLeadingTimestamps(in text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString("") }
        return AttributedString(text)
    }

}
