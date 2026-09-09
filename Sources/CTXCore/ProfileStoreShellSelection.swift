import Foundation

extension ProfileStore {
    /// Records the current selection for shells started outside CTX.
    ///
    /// Writing into someone's home directory is opt-in: defaulted on, running the test
    /// suite overwrote the real `~/.ctx/shell-env` with fixture values.
    ///
    /// Kubernetes is absent because `kubectl` reads a current context from the
    /// kubeconfig already; Azure has no per-shell switch at all.
    @MainActor
    public func recordShellSelection() {
        guard let shellSelectionURL else { return }

        var environment: [String: String] = [:]
        if !activeAWSProfile.isEmpty {
            environment["AWS_PROFILE"] = activeAWSProfile
        }
        if !activeGCPProfile.isEmpty {
            environment["CLOUDSDK_ACTIVE_CONFIG_NAME"] = activeGCPProfile
        }

        // Recording a convenience must never fail an activation.
        try? ShellIntegration.writeSelection(environment, to: shellSelectionURL)
    }
}
