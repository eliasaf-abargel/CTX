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
            ScrollViewReader { proxy in
                List(selection: $viewModel.selectedSection) {
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
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                // A `List(selection:)` doesn't reliably keep the selected row in
                // view on its own — if the list had scrolled away from it (e.g.
                // after selecting one of the last rows, like Diff/Port Forward)
                // and the selection then changes back to a row further up (most
                // commonly Overview), the list can stay scrolled where it was,
                // leaving the selected/topmost sections above the visible area
                // and colliding with the window's own title bar. Explicitly
                // scrolling to the selected section keeps it in view no matter
                // where the list was previously scrolled.
                //
                // Deliberately no `anchor:` here (defaults to nil = "scroll the
                // minimum amount needed to make it visible"). `anchor: .center`
                // was tried first and made things worse: with all 15 sections
                // comfortably fitting the window's height already, forcing a
                // mid/late-list row (e.g. Map, 11th of 15) to the vertical
                // center has no real headroom below it to balance against, so
                // it scrolled as far down as the content allowed anyway —
                // pushing the earlier rows up above the visible area and back
                // into the same title-bar collision this was meant to fix.
                .onChange(of: viewModel.selectedSection) { _, newValue in
                    proxy.scrollTo(newValue)
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.displayUserName)
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
