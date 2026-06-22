import CTXCore
import SwiftUI

struct ProfileRowActions: View {
    let folders: [CloudFolder]
    let edit: () -> Void
    let duplicate: () -> Void
    let move: (CloudFolder) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            CompactIconButton("pencil", help: "Edit", action: edit)
            CompactIconButton("plus.square.on.square", help: "Duplicate", action: duplicate)

            Menu {
                ForEach(folders) { folder in
                    Button(folder.name) { move(folder) }
                }
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move")

            CompactIconButton("trash", help: "Delete", action: delete)
        }
        .controlSize(.mini)
    }
}

struct CompactIconButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.helpText = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(helpText)
    }
}
