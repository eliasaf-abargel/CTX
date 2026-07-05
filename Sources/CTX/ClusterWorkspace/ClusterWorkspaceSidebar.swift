import CTXCore
import SwiftUI

struct ClusterWorkspaceSidebar: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private var primarySections: [ClusterWorkspaceSection] {
        ClusterWorkspaceSection.allCases.filter { !$0.isFuture }
    }

    private var futureSections: [ClusterWorkspaceSection] {
        ClusterWorkspaceSection.allCases.filter(\.isFuture)
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedSection) {
                Section("Cluster") {
                    ForEach(primarySections) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .lineLimit(1)
                            .help(section.rawValue)
                            .tag(section)
                    }
                }

                Section("Future") {
                    ForEach(futureSections) { section in
                        HStack(spacing: 7) {
                            Label(section.rawValue, systemImage: section.systemImage)
                                .lineLimit(1)
                            Spacer()
                            Text("Future")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.tertiary.opacity(0.12), in: Capsule())
                        }
                        .foregroundStyle(.tertiary)
                        .help("\(section.rawValue) is reserved for a later safety-reviewed workflow")
                        .accessibilityLabel("\(section.rawValue), future disabled")
                    }
                }
            }
            .listStyle(.sidebar)

            ClusterWorkspaceSidebarFooter(viewModel: viewModel)
        }
    }
}

private struct ClusterWorkspaceSidebarFooter: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.userName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.userName)
                Text("Inspect mode")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .help("Safe inspection workspace. No cluster changes are made.")
    }
}
