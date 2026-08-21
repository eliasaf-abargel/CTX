import Foundation

extension ProfileStore {
    /// A nonzero cloud CLI exit is authoritative. StrongDM and Teleport are
    /// excluded because their verification poll resolves authentication.
    internal func reportLoginFailure(
        _ result: CommandResult,
        for profile: CloudProfile,
        operationID: UUID? = nil,
        origin: ProfilePresentationSurface = .mainWindow
    ) {
        if let operationID, !isCurrentOperation(profileID: profile.id, operationID: operationID) {
            return
        }
        dismissLifecyclePresentation(for: profile.id, from: origin)
        var message = result.output
        if profile.provider == .aws, let conflict = AWSCredentialsFileAudit.conflict(for: profile.name) {
            message += "\n\n" + conflict.explanation
        }
        report(message, title: "Connection Failed", from: origin)
    }

    internal func logConnectCall(step: String, kind: String, profileID: String, started: Date, outcome: String) {
        CTXPerfLog.log(
            step: step,
            contextID: profileID,
            namespace: "cluster",
            kind: kind,
            cache: .none,
            durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            outcome: outcome == "success" ? .success : .error
        )
    }

    internal func openAuthURLIfPresent(
        _ text: String,
        email: String? = nil,
        operationID: UUID? = nil,
        profileID: String? = nil,
        origin: ProfilePresentationSurface = .mainWindow
    ) {
        if let operationID, let profileID,
           !isCurrentOperation(profileID: profileID, operationID: operationID) {
            return
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: text.utf16.count)
        )
        for match in matches ?? [] {
            guard let url = match.url, url.scheme?.hasPrefix("http") == true else { continue }
            if let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost" {
                continue
            }
            guard let operationID, let profileID else { return }
            present(
                .inAppAuth(
                    InAppAuthPresentation(
                        url: url,
                        email: email,
                        profileID: profileID,
                        operationID: operationID
                    )
                ),
                from: origin
            )
            break
        }
    }

    internal func dismissInAppAuth(
        profileID: String,
        operationID: UUID,
        origin: ProfilePresentationSurface
    ) {
        guard let current = presentation,
              current.requestedOrigin == origin,
              case .inAppAuth(let request) = current.route,
              request.profileID == profileID,
              request.operationID == operationID else {
            return
        }
        presentation = nil
    }

    internal func dismissLifecyclePresentation(
        for profileID: String,
        from origin: ProfilePresentationSurface
    ) {
        guard let current = presentation, current.requestedOrigin == origin else { return }
        switch current.route {
        case .missingCLI(let request) where request.profile.id == profileID:
            presentation = nil
        case .inAppAuth(let request) where request.profileID == profileID:
            presentation = nil
        default:
            break
        }
    }

    public func cancelPresentation(id: UUID, from surface: ProfilePresentationSurface) {
        guard let current = presentation,
              current.id == id,
              current.origin == surface else {
            return
        }
        if case .inAppAuth(let request) = current.route,
           isCurrentOperation(profileID: request.profileID, operationID: request.operationID) {
            if let profile = profiles.first(where: { $0.id == request.profileID }) {
                updateStatus(profile, status: .needsLogin, operationID: request.operationID)
            }
            cancelProfileOperation(profileID: request.profileID)
        }
        consumePresentation(id: id, from: surface)
    }
}
