import SwiftUI

/// One overridable config-file location.
///
/// An empty `path` means "use the default" — that is also how every parser in
/// CTXCore reads these keys (`!path.isEmpty`), so clearing the binding and
/// removing the key are equivalent.
struct ConfigPathRow: View {
    enum Selects {
        case file
        case directory
    }

    let title: String
    let defaultPath: String
    let selects: Selects
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(abbreviate(path.isEmpty ? defaultPath : path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path.isEmpty ? "\(abbreviate(defaultPath)) (default)" : abbreviate(path))

                Button("Change…") { choose() }
                    .buttonStyle(.link)
                    .focusable(false)

                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("Reset to default")
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = selects == .file
        panel.canChooseDirectories = selects == .directory
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func abbreviate(_ value: String) -> String {
        value.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }
}
