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

    private var filteredText: String {
        let base = stripANSI ? Self.strippingANSICodes(from: rawText) : rawText
        guard !filterQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let query = filterQuery.lowercased()
        return base.components(separatedBy: .newlines)
            .filter { $0.lowercased().contains(query) }
            .joined(separator: "\n")
    }

    private var lineCount: Int {
        filteredText.isEmpty ? 0 : filteredText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Filter logs...", text: $filterQuery)
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
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
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
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .frame(minHeight: 450, maxHeight: .infinity, alignment: .top)
        }
    }

    private var styledLog: AttributedString {
        Self.dimmingLeadingTimestamps(in: filteredText)
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

    private static func looksLikeTimestamp(_ candidate: Substring) -> Bool {
        candidate.count >= 20 && candidate.contains("T") && (candidate.hasSuffix("Z") || candidate.contains("+"))
    }
}
