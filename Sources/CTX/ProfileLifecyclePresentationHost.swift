import CTXCore
import SwiftUI

struct ProfileLifecyclePresentationHost: ViewModifier {
    @ObservedObject var store: ProfileStore
    let surface: ProfilePresentationSurface
    @State private var presentedSheetID: UUID?
    @State private var presentedAlertID: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding) { presentation in
                LifecycleSheetContent(
                    store: store,
                    surface: surface,
                    presentationID: presentation.id,
                    onPresented: { presentedSheetID = presentation.id }
                )
                .id(presentation.id)
            }
            .alert(
                operationError?.title ?? "Operation Failed",
                isPresented: operationErrorBinding,
                presenting: operationError
            ) { _ in
                Button("OK", role: .cancel) {
                    consumePresentedAlert()
                }
            } message: { error in
                Text(error.message)
            }
            .confirmationDialog(
                folderDeletion.map { "Delete \($0.folder.name)?" } ?? "Delete Folder?",
                isPresented: folderDeletionBinding,
                titleVisibility: .visible,
                presenting: folderDeletion
            ) { request in
                Button("Delete Folder", role: .destructive) {
                    store.confirmFolderDeletion(
                        request.folder,
                        presentationID: request.id,
                        from: surface
                    )
                }
                Button("Cancel", role: .cancel) {
                    store.consumePresentation(id: request.id, from: surface)
                }
            } message: { _ in
                Text("This removes only the folder organization. Profiles in the folder remain available.")
            }
            .confirmationDialog(
                providerSignOut?.confirmation.title ?? "Sign Out from Provider?",
                isPresented: providerSignOutBinding,
                titleVisibility: .visible,
                presenting: providerSignOut
            ) { request in
                Button(request.confirmation.confirmLabel, role: .destructive) {
                    store.confirmProviderSignOut(
                        request.confirmation,
                        presentationID: request.id,
                        from: surface
                    )
                }
                Button("Cancel", role: .cancel) {
                    store.consumePresentation(id: request.id, from: surface)
                }
            } message: { request in
                Text(request.confirmation.warning)
            }
            .onChange(of: store.presentation?.id, initial: true) { _, _ in
                if let presentation = store.presentation(for: surface),
                   presentation.route.isAlert {
                    presentedAlertID = presentation.id
                }
            }
    }

    private var sheetBinding: Binding<ProfilePresentation?> {
        Binding(
            get: {
                guard let presentation = store.presentation(for: surface),
                      presentation.route.isSheet else {
                    return nil
                }
                return presentation
            },
            set: { newValue in
                guard newValue == nil, let id = presentedSheetID else { return }
                store.cancelPresentation(id: id, from: surface)
                presentedSheetID = nil
            }
        )
    }

    private var operationError: ProfileOperationError? {
        guard let presentation = store.presentation(for: surface),
              case .operationError(let error) = presentation.route else { return nil }
        return error
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { if !$0 { consumePresentedAlert() } }
        )
    }

    private var folderDeletion: (id: UUID, folder: CloudFolder)? {
        guard let presentation = store.presentation(for: surface),
              case .folderDeletionConfirmation(let folder) = presentation.route else { return nil }
        return (presentation.id, folder)
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { folderDeletion != nil },
            set: { if !$0 { consumePresentedAlert() } }
        )
    }

    private var providerSignOut: (id: UUID, confirmation: ProviderSignOutConfirmation)? {
        guard let presentation = store.presentation(for: surface),
              case .providerSignOutConfirmation(let confirmation) = presentation.route else { return nil }
        return (presentation.id, confirmation)
    }

    private var providerSignOutBinding: Binding<Bool> {
        Binding(
            get: { providerSignOut != nil },
            set: { if !$0 { consumePresentedAlert() } }
        )
    }

    private func consumePresentedAlert() {
        guard let id = presentedAlertID else { return }
        store.consumePresentation(id: id, from: surface)
        presentedAlertID = nil
    }
}

private struct LifecycleSheetContent: View {
    @ObservedObject var store: ProfileStore
    let surface: ProfilePresentationSurface
    let presentationID: UUID
    let onPresented: () -> Void

    var body: some View {
        Group {
            if let presentation = store.presentation(for: surface),
               presentation.id == presentationID {
                sheet(for: presentation)
                    .id(presentation.route.contentIdentity)
            }
        }
        .onAppear(perform: onPresented)
        .onDisappear {
            store.consumePresentation(id: presentationID, from: surface)
        }
    }

    @ViewBuilder
    private func sheet(for presentation: ProfilePresentation) -> some View {
        switch presentation.route {
        case .profileEditor(let intent):
            profileEditor(intent)
        case .folderEditor(let intent):
            switch intent {
            case .add:
                FolderEditorView(
                    store: store,
                    origin: surface,
                    presentationID: presentationID
                )
            case .edit(let folder):
                FolderEditorView(
                    store: store,
                    folder: folder,
                    origin: surface,
                    presentationID: presentationID
                )
            }
        case .missingCLI(let request):
            MissingCLIToolSheet(store: store, request: request, origin: surface)
        case .inAppAuth(let request):
            InAppAuthWebModalView(url: request.url, userEmail: request.email) { result in
                switch result {
                case .success:
                    store.consumePresentation(id: presentationID, from: surface)
                case .failure:
                    store.cancelPresentation(id: presentationID, from: surface)
                }
            }
        case .pendingFolderAssignment(let profile):
            ChooseFolderPromptView(store: store, profile: profile, origin: surface)
        case .operationError, .folderDeletionConfirmation, .providerSignOutConfirmation:
            EmptyView()
        }
    }

    @ViewBuilder
    private func profileEditor(_ intent: ProfileEditorIntent) -> some View {
        switch intent {
        case .selectProvider(let targetFolder):
            SelectProviderView(store: store, targetFolder: targetFolder, origin: surface)
        case .add(let provider, let targetFolder):
            switch provider {
            case .aws:
                AddAWSProfileView(store: store, targetFolder: targetFolder, origin: surface)
            case .gcp:
                AddGCPProfileView(store: store, targetFolder: targetFolder, origin: surface)
            case .azure:
                AddAzureProfileView(store: store, targetFolder: targetFolder, origin: surface)
            case .kubernetes:
                AddKubeContextView(store: store, targetFolder: targetFolder, origin: surface)
            }
        case .edit(let profile, let targetFolder):
            switch profile.provider {
            case .aws:
                AddAWSProfileView(store: store, mode: .edit(profile), targetFolder: targetFolder, origin: surface)
            case .gcp:
                AddGCPProfileView(store: store, mode: .edit(profile), targetFolder: targetFolder, origin: surface)
            case .azure:
                AddAzureProfileView(store: store, mode: .edit(profile), targetFolder: targetFolder, origin: surface)
            case .kubernetes:
                AddKubeContextView(store: store, mode: .edit(profile), targetFolder: targetFolder, origin: surface)
            }
        case .duplicate(let profile, let targetFolder):
            switch profile.provider {
            case .aws:
                AddAWSProfileView(store: store, mode: .duplicate(profile), targetFolder: targetFolder, origin: surface)
            case .gcp:
                AddGCPProfileView(store: store, mode: .duplicate(profile), targetFolder: targetFolder, origin: surface)
            case .azure:
                AddAzureProfileView(store: store, mode: .duplicate(profile), targetFolder: targetFolder, origin: surface)
            case .kubernetes:
                AddKubeContextView(store: store, mode: .duplicate(profile), targetFolder: targetFolder, origin: surface)
            }
        }
    }
}

private extension ProfilePresentationRoute {
    /// Distinguishes the content shown inside one sheet, so swapping routes
    /// without re-presenting still resets form state and re-measures the sheet.
    var contentIdentity: String {
        switch self {
        case .profileEditor(let intent):
            switch intent {
            case .selectProvider:
                "editor.selectProvider"
            case .add(let provider, _):
                "editor.add.\(provider.rawValue)"
            case .edit(let profile, _):
                "editor.edit.\(profile.id)"
            case .duplicate(let profile, _):
                "editor.duplicate.\(profile.id)"
            }
        case .folderEditor(let intent):
            switch intent {
            case .add:
                "folder.add"
            case .edit(let folder):
                "folder.edit.\(folder.id)"
            }
        case .missingCLI(let request):
            "missingCLI.\(request.tool.binary)"
        case .inAppAuth(let request):
            "auth.\(request.url.absoluteString)"
        case .pendingFolderAssignment(let profile):
            "folderAssignment.\(profile.id)"
        case .operationError, .folderDeletionConfirmation, .providerSignOutConfirmation:
            "alert"
        }
    }

    var isSheet: Bool {
        switch self {
        case .profileEditor, .folderEditor, .missingCLI, .inAppAuth, .pendingFolderAssignment:
            true
        case .operationError, .folderDeletionConfirmation, .providerSignOutConfirmation:
            false
        }
    }

    var isAlert: Bool {
        !isSheet
    }
}

extension View {
    func profileLifecyclePresentationHost(
        store: ProfileStore,
        surface: ProfilePresentationSurface
    ) -> some View {
        modifier(ProfileLifecyclePresentationHost(store: store, surface: surface))
    }
}
