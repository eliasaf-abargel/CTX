import CTXCore
import SwiftUI

struct ClusterNamespaceSelector: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var isPresented = false
    @State private var filter = ""

    private var filteredNamespaces: [String] {
        let options = viewModel.availableNamespaces.filter { $0 != "default" }
        guard !filter.isEmpty else { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedNamespace == .allNamespaces ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                Text(viewModel.namespace)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 190, alignment: .leading)
            .background(.blue.opacity(0.11), in: Capsule())
            .overlay {
                Capsule().stroke(.blue.opacity(0.24), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            selectorContent
                .frame(width: 260, height: 340)
        }
        .help("Workspace namespace: \(viewModel.namespace)")
    }

    private var selectorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Namespace")
                .font(.headline)
            CTXSearchField(placeholder: "Filter namespaces", text: $filter)

            ScrollView {
                VStack(spacing: 4) {
                    namespaceButton(.allNamespaces, title: "All namespaces", systemImage: "square.stack.3d.up.fill")
                    namespaceButton(.defaultNamespace, title: "default", systemImage: "square.stack.3d.up")

                    if !filteredNamespaces.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(filteredNamespaces, id: \.self) { namespace in
                            namespaceButton(namespace == "default" ? .defaultNamespace : .namespace(namespace), title: namespace, systemImage: "square.stack.3d.up")
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func namespaceButton(_ selection: KubernetesNamespaceSelection, title: String, systemImage: String) -> some View {
        Button {
            viewModel.setNamespace(selection)
            isPresented = false
            filter = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(selection == viewModel.selectedNamespace ? .blue : .secondary)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if selection == viewModel.selectedNamespace {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selection == viewModel.selectedNamespace ? .blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
