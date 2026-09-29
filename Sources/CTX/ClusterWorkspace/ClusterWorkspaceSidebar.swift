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

    private var sectionBinding: Binding<ClusterWorkspaceSection?> {
        Binding(
            get: { viewModel.selectedSection },
            set: { newValue in
                guard let newValue else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    viewModel.selectedSection = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: sectionBinding) {
                    Section("Cluster") {
                        ForEach(primarySections) { section in
                            Label(section.rawValue, systemImage: section.systemImage)
                                .lineLimit(1)
                                .help(section.rawValue)
                                .tag(section)
                                .id(section)
                        }
                    }

                    if !futureSections.isEmpty {
                        Section("Future") {
                            ForEach(futureSections) { section in
                                HStack(spacing: 7) {
                                    Label(section.rawValue, systemImage: section.systemImage)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Future")
                                        .font(.system(.caption2, weight: .bold))
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
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.selectedSection) { _, newValue in
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo(newValue)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(viewModel.selectedSection)
                    }
                }
            }

            ClusterWorkspaceSidebarFooter(viewModel: viewModel)
        }
    }
}

private struct ClusterWorkspaceSidebarFooter: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.displayUserName)
                    .font(.system(.caption2, weight: .semibold))
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
