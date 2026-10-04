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
                    ForEach(ClusterWorkspaceCategory.allCases) { category in
                        let sections = primarySections.filter { $0.category == category }
                        if !sections.isEmpty {
                            Section(category.rawValue) {
                                ForEach(sections) { section in
                                    ClusterWorkspaceSidebarRow(
                                        section: section,
                                        isSelected: viewModel.selectedSection == section
                                    )
                                    .tag(section)
                                    .id(section)
                                }
                            }
                        }
                    }

                    if !futureSections.isEmpty {
                        Section("Future") {
                            ForEach(futureSections) { section in
                                HStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.secondary.opacity(0.15))
                                            .frame(width: 20, height: 20)
                                        Image(systemName: section.badgeIcon)
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(section.rawValue)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
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

private struct ClusterWorkspaceSidebarRow: View {
    let section: ClusterWorkspaceSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(section.badgeColor.gradient)
                    .frame(width: 20, height: 20)
                    .shadow(color: section.badgeColor.opacity(0.25), radius: 1, x: 0, y: 0.5)

                Image(systemName: section.badgeIcon)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(section.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help(section.rawValue)
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
