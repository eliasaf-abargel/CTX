import Foundation

public enum ProfilePresentationSurface: String, Sendable {
    case mainWindow
    case menuBar
    case settings
}

public enum ProfileEditorIntent: Identifiable, Sendable {
    case selectProvider(targetFolder: CloudFolder?)
    case add(provider: CloudProvider, targetFolder: CloudFolder?)
    case edit(profile: CloudProfile, targetFolder: CloudFolder)
    case duplicate(profile: CloudProfile, targetFolder: CloudFolder)

    public var id: String {
        switch self {
        case .selectProvider(let folder):
            "select-provider:\(folder?.id ?? "unassigned")"
        case .add(let provider, let folder):
            "add:\(provider.rawValue):\(folder?.id ?? "unassigned")"
        case .edit(let profile, _):
            "edit:\(profile.id)"
        case .duplicate(let profile, _):
            "duplicate:\(profile.id)"
        }
    }
}

public enum FolderEditorIntent: Identifiable, Sendable {
    case add
    case edit(CloudFolder)

    public var id: String {
        switch self {
        case .add:
            "add-folder"
        case .edit(let folder):
            "edit-folder:\(folder.id)"
        }
    }
}

public struct InAppAuthPresentation: Sendable {
    public let url: URL
    public let email: String?
    public let profileID: String
    public let operationID: UUID

    public init(url: URL, email: String?, profileID: String, operationID: UUID) {
        self.url = url
        self.email = email
        self.profileID = profileID
        self.operationID = operationID
    }
}

public struct ProfileOperationError: Sendable {
    public let title: String
    public let message: String

    public init(title: String = "Operation Failed", message: String) {
        self.title = title
        self.message = message
    }
}

public struct ProviderSignOutConfirmation: Identifiable, Sendable {
    public var id: String { profile.id }
    public let profile: CloudProfile
    public let title: String
    public let warning: String
    public let confirmLabel: String

    public init(profile: CloudProfile, title: String, warning: String, confirmLabel: String) {
        self.profile = profile
        self.title = title
        self.warning = warning
        self.confirmLabel = confirmLabel
    }
}

public enum ProfilePresentationRoute: Sendable {
    case profileEditor(ProfileEditorIntent)
    case folderEditor(FolderEditorIntent)
    case missingCLI(MissingCLIToolRequest)
    case inAppAuth(InAppAuthPresentation)
    case operationError(ProfileOperationError)
    case pendingFolderAssignment(CloudProfile)
    case folderDeletionConfirmation(CloudFolder)
    case providerSignOutConfirmation(ProviderSignOutConfirmation)
}

public struct ProfilePresentation: Identifiable, Sendable {
    public let id: UUID
    public let origin: ProfilePresentationSurface
    public let requestedOrigin: ProfilePresentationSurface
    public let route: ProfilePresentationRoute

    public init(
        id: UUID = UUID(),
        origin: ProfilePresentationSurface,
        requestedOrigin: ProfilePresentationSurface? = nil,
        route: ProfilePresentationRoute
    ) {
        self.id = id
        self.origin = origin
        self.requestedOrigin = requestedOrigin ?? origin
        self.route = route
    }
}

internal struct DeferredProfilePresentation {
    let expectedPresentationID: UUID
    let route: ProfilePresentationRoute
    let origin: ProfilePresentationSurface
}

extension ProfileStore {
    public func presentation(for surface: ProfilePresentationSurface) -> ProfilePresentation? {
        guard presentation?.origin == surface else { return nil }
        return presentation
    }

    public func present(_ route: ProfilePresentationRoute, from origin: ProfilePresentationSurface) {
        let hostOrigin: ProfilePresentationSurface = origin == .menuBar ? .mainWindow : origin
        if let current = presentation,
           current.origin == hostOrigin,
           current.route.isSheet,
           route.isAlert {
            deferredPresentation = DeferredProfilePresentation(
                expectedPresentationID: current.id,
                route: route,
                origin: origin
            )
            return
        }
        deferredPresentation = nil
        presentation = ProfilePresentation(
            origin: hostOrigin,
            requestedOrigin: origin,
            route: route
        )
    }

    public func consumePresentation(id: UUID, from surface: ProfilePresentationSurface) {
        guard presentation?.id == id, presentation?.origin == surface else { return }
        let deferred = deferredPresentation?.expectedPresentationID == id
            ? deferredPresentation
            : nil
        deferredPresentation = nil
        presentation = nil
        guard let deferred else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.presentation == nil else { return }
            self.present(deferred.route, from: deferred.origin)
        }
    }

    public func dismissPresentation(from surface: ProfilePresentationSurface) {
        guard let current = presentation, current.origin == surface else { return }
        consumePresentation(id: current.id, from: surface)
    }

    public func presentProfileEditor(
        _ intent: ProfileEditorIntent,
        from origin: ProfilePresentationSurface
    ) {
        let hostOrigin: ProfilePresentationSurface = origin == .menuBar ? .mainWindow : origin
        if let current = presentation,
           current.origin == hostOrigin,
           case .profileEditor = current.route {
            // Stepping from provider selection into an editor is one navigation,
            // so the sheet keeps its identity and only swaps content. Tearing it
            // down and re-presenting plays a close/open animation that reads as
            // a stall.
            deferredPresentation = nil
            presentation = ProfilePresentation(
                id: current.id,
                origin: hostOrigin,
                requestedOrigin: origin,
                route: .profileEditor(intent)
            )
        } else {
            present(.profileEditor(intent), from: origin)
        }
    }

    public func presentFolderEditor(
        _ intent: FolderEditorIntent,
        from origin: ProfilePresentationSurface
    ) {
        present(.folderEditor(intent), from: origin)
    }

    public func requestFolderDeletion(
        _ folder: CloudFolder,
        from origin: ProfilePresentationSurface
    ) {
        present(.folderDeletionConfirmation(folder), from: origin)
    }

    public func requestProviderSignOut(
        _ profile: CloudProfile,
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        guard let confirmation = providerSignOutConfirmation(for: profile) else {
            report(
                "CTX cannot determine which provider account belongs to \(profile.name). Add an account to the profile before signing out.",
                title: "Provider Account Required",
                from: origin
            )
            return
        }
        present(.providerSignOutConfirmation(confirmation), from: origin)
    }

    public func confirmProviderSignOut(
        _ confirmation: ProviderSignOutConfirmation,
        presentationID: UUID? = nil,
        from origin: ProfilePresentationSurface
    ) {
        guard let current = presentation,
              current.origin == origin,
              presentationID == nil || current.id == presentationID,
              case .providerSignOutConfirmation(let requested) = current.route,
              requested.profile.id == confirmation.profile.id,
              requested.profile.provider == confirmation.profile.provider else {
            return
        }
        presentation = nil
        beginProviderSignOut(requested.profile, from: current.requestedOrigin)
    }

    public func requestFolderDeletionAfterDismissingEditor(
        _ folder: CloudFolder,
        editorPresentationID: UUID,
        from origin: ProfilePresentationSurface
    ) {
        guard presentation?.id == editorPresentationID,
              presentation?.origin == origin else {
            return
        }
        deferredPresentation = DeferredProfilePresentation(
            expectedPresentationID: editorPresentationID,
            route: .folderDeletionConfirmation(folder),
            origin: origin
        )
        consumePresentation(id: editorPresentationID, from: origin)
    }

    public func confirmFolderDeletion(
        _ folder: CloudFolder,
        presentationID: UUID? = nil,
        from origin: ProfilePresentationSurface
    ) {
        guard let current = presentation,
              current.origin == origin,
              presentationID == nil || current.id == presentationID,
              case .folderDeletionConfirmation(let requestedFolder) = current.route,
              requestedFolder.id == folder.id else {
            return
        }
        presentation = nil
        deleteFolder(folder)
    }

    public func report(
        _ message: String,
        title: String = "Operation Failed",
        from origin: ProfilePresentationSurface = .mainWindow
    ) {
        present(
            .operationError(ProfileOperationError(title: title, message: sanitizedLifecycleMessage(message))),
            from: origin
        )
    }

    public func reportStatus(_ message: String) {
        lastMessage = message
    }
}

extension ProfilePresentationRoute {
    internal var isSheet: Bool {
        switch self {
        case .profileEditor, .folderEditor, .missingCLI, .inAppAuth, .pendingFolderAssignment:
            true
        case .operationError, .folderDeletionConfirmation, .providerSignOutConfirmation:
            false
        }
    }

    internal var isAlert: Bool {
        !isSheet
    }
}
