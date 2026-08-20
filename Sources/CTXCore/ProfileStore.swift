import Combine
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum ActiveSheetType: String, Sendable {
    case addAWSProfile
    case addGCPProfile
    case addAzureProfile
    case addKubeContext
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public var triggerSheet: ActiveSheetType? = nil
    @Published public internal(set) var profiles: [CloudProfile] = [] {
        didSet { rebuildGroupedProfiles() }
    }
    @Published public var selectedSelection: SidebarSelection?
    @Published public internal(set) var activeAWSProfile: String
    @Published public internal(set) var activeGCPProfile: String
    @Published public internal(set) var activeAzureProfile: String
    @Published public internal(set) var activeKubeContext: String
    @Published public internal(set) var kubernetesContexts: [KubernetesContextProfile] = []
    @Published public internal(set) var lastMessage = ""
    @Published public internal(set) var lastLoginAt: Date?
    @Published public internal(set) var lastVerifiedAt: Date?
    @Published public internal(set) var lastCommandDuration: TimeInterval?
    @Published public internal(set) var customFolders: [CloudFolder] = [] {
        didSet { rebuildFolders() }
    }
    @Published public internal(set) var folderCustomizations: [String: CloudFolder] = [:] {
        didSet { rebuildFolders() }
    }
    @Published public internal(set) var folderOverrides: [String: String] = [:] {
        didSet { rebuildGroupedProfiles() }
    }
    @Published public internal(set) var hiddenFolderIDs: Set<String> = [] {
        didSet { rebuildFolders() }
    }
    @Published public var showExpirationWarning = false
    @Published public var connectionErrorMessage: String? = nil
    @Published public var verificationErrors: [String: String] = [:]
    /// Set right after a profile/context is created outside of any folder context
    /// (e.g. via the sidebar's global "+" button) so the UI can ask which folder it
    /// belongs in, instead of silently leaving it in the generic default folder.
    @Published public var activeInAppAuthURL: URL? = nil
    /// Set when a connect is blocked because the provider's CLI isn't on the Mac.
    @Published public var missingCLITool: MissingCLIToolRequest? = nil
    @Published public var activeInAppAuthEmail: String? = nil
    @Published public var pendingFolderPrompt: CloudProfile? = nil
    @Published public var expirationWarningMessage = ""
    @Published public var updateAvailable = false
    @Published public var latestVersionString = ""
    @Published public var isUpdating = false
    @Published public var selectedSettingsTab = 0
    @Published public var isCheckingForUpdates = false
    @Published public var updateCheckMessage = ""
    /// Identity (e.g. SSO email / IAM user) resolved from the active AWS caller-identity.
    @Published public internal(set) var awsIdentity = ""
    /// Expiry of the active AWS SSO session, used for the live countdown in the toolbar.
    @Published public internal(set) var activeAWSExpiresAt: Date?

    internal let configURL: URL
    internal let runner: any CloudCommandRunning
    internal let kubeConfigMutations: KubeConfigMutationService
    internal let kubeConfigDiscoveryService: KubeConfigDiscoveryService
    internal let localProfileDiscovery: LocalProfileDiscoveryService
    internal let profileCommands: ProfileCommandService
    internal let updateService: CTXUpdateService
    internal let awsSessionExpirations: AWSSessionExpirationService
    internal let notifications: AppNotificationService
    internal let awsCredentials: AWSCredentialService
    internal let profilePersistence: CloudProfilePersistenceService
    internal let fileWatchers: ProfileFileWatcherService
    internal let folderPreferences: CloudFolderPreferencesStore
    internal let missingCLIToolResolver: MissingCLIToolResolving
    internal var manuallyDisconnectedProfiles: Set<String> = []
    internal var lastExpirationWarningTime: Date?
    internal var expirationTimer: AnyCancellable?
    internal var lastCacheCheckTime = Date.distantPast
    internal var isCheckingSessionExpiration = false
    internal var verificationTask: Task<Void, Never>?
    internal var pendingVerificationRequest = false
    internal var gcpManuallyClearedByUser = false
    internal var refreshDebounceTask: Task<Void, Never>?
    internal var gcpActiveConfigDebounceTask: Task<Void, Never>?

    @Published public internal(set) var allFolders: [CloudFolder] = []
    @Published public internal(set) var groupedProfiles: [ProfileGroup] = []
    internal var folderIndex: [String: CloudFolder] = [:]
    internal var foldersByProvider: [CloudProvider: [CloudFolder]] = [:]

    public init(
        configURL: URL = AWSConfigPaths.configURL,
        runner: any CloudCommandRunning = CloudCommandRunner(),
        kubeConfigMutations: KubeConfigMutationService? = nil,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService = KubeConfigDiscoveryService(),
        profileCommands: ProfileCommandService? = nil,
        updateService: CTXUpdateService? = nil,
        awsSessionExpirations: AWSSessionExpirationService = AWSSessionExpirationService(),
        notifications: AppNotificationService = AppNotificationService(),
        awsCredentials: AWSCredentialService? = nil,
        profilePersistence: CloudProfilePersistenceService? = nil,
        fileWatchers: ProfileFileWatcherService = ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore = CloudFolderPreferencesStore(),
        missingCLIToolResolver: @escaping MissingCLIToolResolving = { CLITool.firstMissing(for: $0) },
        startsBackgroundServices: Bool = true
    ) {
        self.configURL = configURL
        self.runner = runner
        self.kubeConfigMutations = kubeConfigMutations ?? KubeConfigMutationService(runner: runner)
        self.kubeConfigDiscoveryService = kubeConfigDiscoveryService
        self.localProfileDiscovery = LocalProfileDiscoveryService(awsConfigURL: configURL, kubeConfigDiscoveryService: kubeConfigDiscoveryService)
        self.profileCommands = profileCommands ?? ProfileCommandService(runner: runner)
        self.updateService = updateService ?? CTXUpdateService(runner: runner)
        self.awsSessionExpirations = awsSessionExpirations
        self.notifications = notifications
        self.awsCredentials = awsCredentials ?? AWSCredentialService(configURL: configURL)
        self.profilePersistence = profilePersistence ?? CloudProfilePersistenceService(awsConfigURL: configURL)
        self.fileWatchers = fileWatchers
        self.folderPreferences = folderPreferences
        self.missingCLIToolResolver = missingCLIToolResolver
        self.activeAWSProfile = UserDefaults.standard.string(forKey: "activeAWSProfile") ?? ""
        self.activeGCPProfile = UserDefaults.standard.string(forKey: "activeGCPProfile") ?? ""
        self.activeAzureProfile = UserDefaults.standard.string(forKey: "activeAzureProfile") ?? ""
        self.activeKubeContext = UserDefaults.standard.string(forKey: "activeKubeContext") ?? ""
        self.gcpManuallyClearedByUser = UserDefaults.standard.bool(forKey: "gcpManuallyClearedByUser")
        let folderState = folderPreferences.load()
        self.customFolders = folderState.customFolders
        self.folderCustomizations = folderState.folderCustomizations
        self.folderOverrides = folderState.folderOverrides
        self.hiddenFolderIDs = folderState.hiddenFolderIDs
        rebuildFolders()

        if startsBackgroundServices {
            refresh()
            verifyAllProfiles()

            self.expirationTimer = Timer.publish(every: 10, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.checkAllSessionsExpiration()
                }

            notifications.requestAuthorizationIfAvailable()
            checkForUpdates()
            startAllFileWatchers()

            Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkForUpdates()
                }
            }
        } else {
            refreshImmediately(runVerification: false)
        }
    }

    public var selectedProfile: CloudProfile? {
        if case .profile(let profileID) = selectedSelection {
            return profiles.first { $0.id == profileID }
        }
        return nil
    }

    public var selectedFolder: CloudFolder? {
        if case .folder(let folderID) = selectedSelection {
            return allFolders.first { $0.id == folderID }
        }
        return nil
    }

    public func activeProfile(for provider: CloudProvider) -> CloudProfile? {
        let name: String
        switch provider {
        case .aws: name = activeAWSProfile
        case .gcp: name = activeGCPProfile
        case .azure: name = activeAzureProfile
        case .kubernetes: name = activeKubeContext
        }

        if !name.isEmpty, let p = profiles.first(where: { $0.provider == provider && $0.name == name }), p.status == .connected {
            return p
        }
        return profiles.first(where: { $0.provider == provider && $0.status == .connected })
    }

    public func isActive(_ profile: CloudProfile) -> Bool {
        if let active = activeProfile(for: profile.provider) {
            return active.id == profile.id
        }
        switch profile.provider {
        case .aws:
            return activeAWSProfile == profile.name
        case .gcp:
            return activeGCPProfile == profile.name
        case .azure:
            return activeAzureProfile == profile.name
        case .kubernetes:
            return activeKubeContext == profile.name
        }
    }

    public func setActive(_ profile: CloudProfile) {
        setActive(profile, runActivation: true)
    }

    internal func setActive(_ profile: CloudProfile, runActivation: Bool) {
        if case .profile(let pId) = selectedSelection, pId == profile.id {
            // Already selected
        } else {
            selectedSelection = .profile(profile.id)
        }
        switch profile.provider {
        case .aws:
            let wasActive = activeAWSProfile == profile.name
            if !wasActive {
                activeAWSProfile = profile.name
                UserDefaults.standard.set(profile.name, forKey: "activeAWSProfile")
                lastMessage = "Active AWS_PROFILE=\(profile.name)"
            }

            if wasActive && profile.status == .connected {
                checkAllSessionsExpiration()
                return
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try self.awsCredentials.syncDefaultProfile(from: profile.name)
                } catch {
                    await MainActor.run {
                        self.lastMessage = "Failed to sync default credentials: \(error.localizedDescription)"
                    }
                }
                await MainActor.run {
                    self.checkAllSessionsExpiration()
                }
            }
        case .gcp:
            let wasActive = activeGCPProfile == profile.name
            if !wasActive {
                activeGCPProfile = profile.name
                UserDefaults.standard.set(profile.name, forKey: "activeGCPProfile")
                lastMessage = "Active GCP configuration=\(profile.name)"
            }
            gcpManuallyClearedByUser = false
            UserDefaults.standard.set(false, forKey: "gcpManuallyClearedByUser")
            guard runActivation else { return }
            if wasActive && profile.status == .connected { return }

            Task {
                let startedAt = Date()
                let result = await profileCommands.activateGCPConfiguration(profile)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastMessage = "Activated GCP configuration \(profile.name)"
                } else {
                    lastMessage = "Failed to activate GCP configuration: \(result.output)"
                }
                await verify(profile)
            }
        case .azure:
            let wasActive = activeAzureProfile == profile.name
            if !wasActive {
                activeAzureProfile = profile.name
                UserDefaults.standard.set(profile.name, forKey: "activeAzureProfile")
                lastMessage = "Active Azure subscription=\(profile.name)"
            }
            guard runActivation else { return }
            if wasActive && profile.status == .connected { return }

            Task {
                let startedAt = Date()
                let result = await profileCommands.activateAzureSubscription(profile)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastMessage = "Activated Azure subscription \(profile.name)"
                } else {
                    lastMessage = "Failed to activate Azure subscription: \(result.output)"
                }
                await verify(profile)
            }
        case .kubernetes:
            let wasActive = activeKubeContext == profile.name
            if !wasActive {
                activeKubeContext = profile.name
                UserDefaults.standard.set(profile.name, forKey: "activeKubeContext")
                lastMessage = "Active kube context=\(profile.name)"
            }
            guard runActivation else { return }
            if wasActive && profile.status == .connected { return }

            Task {
                let startedAt = Date()
                let result = await kubeConfigMutations.useContext(profile.name, kubeconfigPath: kubeconfigPath(for: profile.name))
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastMessage = "Switched kube context to \(profile.name)"
                } else {
                    lastMessage = "Failed to switch context: \(result.output)"
                }
                verifyAllProfiles()
            }
        }
    }

    public func clearActive(for provider: CloudProvider) {
        switch provider {
        case .aws:
            activeAWSProfile = ""
            UserDefaults.standard.removeObject(forKey: "activeAWSProfile")
            awsIdentity = ""
            activeAWSExpiresAt = nil
            lastMessage = "No active AWS profile"
            do {
                try awsCredentials.clearDefaultProfile()
            } catch {
                // Ignore clearing errors
            }
        case .gcp:
            gcpManuallyClearedByUser = true
            UserDefaults.standard.set(true, forKey: "gcpManuallyClearedByUser")
            activeGCPProfile = ""
            UserDefaults.standard.removeObject(forKey: "activeGCPProfile")
            lastMessage = "No active GCP configuration"
        case .azure:
            activeAzureProfile = ""
            UserDefaults.standard.removeObject(forKey: "activeAzureProfile")
            lastMessage = "No active Azure subscription"
        case .kubernetes:
            activeKubeContext = ""
            UserDefaults.standard.removeObject(forKey: "activeKubeContext")
            lastMessage = "No active kube context"
        }
        showExpirationWarning = false
    }

    public func clearActive() {
        clearActive(for: .aws)
    }

    public func report(_ message: String) {
        lastMessage = message
    }

    // MARK: - Active identity

    public var activeIdentityLabel: String {
        if !activeGCPProfile.isEmpty,
           let gcp = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPProfile }),
           !gcp.roleName.isEmpty {
            return gcp.roleName
        }
        if !awsIdentity.isEmpty {
            return awsIdentity
        }
        if !activeAWSProfile.isEmpty,
           let aws = profiles.first(where: { $0.provider == .aws && $0.name == activeAWSProfile }) {
            return aws.accountID.isEmpty ? aws.name : "\(aws.name) · \(aws.accountID)"
        }
        let fullName = NSFullUserName()
        return fullName.isEmpty ? NSUserName() : fullName
    }

    public var activeIdentityInitials: String {
        let label = activeIdentityLabel
        let base = label.contains("@") ? String(label.split(separator: "@").first ?? "") : label
        let parts = base
            .split(whereSeparator: { $0 == "." || $0 == " " || $0 == "-" || $0 == "_" })
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(base.prefix(2)).uppercased()
    }

    public var hasActiveConnectedProfile: Bool {
        profiles.contains { profile in
            isActive(profile) && profile.status == .connected
        }
    }

    public var isCloudIdentityActive: Bool {
        if !activeAWSProfile.isEmpty,
           let aws = profiles.first(where: { $0.provider == .aws && $0.name == activeAWSProfile }),
           aws.status == .connected {
            return true
        }
        if !activeGCPProfile.isEmpty,
           let gcp = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPProfile }),
           gcp.status == .connected {
            return true
        }
        if !activeAzureProfile.isEmpty,
           let azure = profiles.first(where: { $0.provider == .azure && $0.name == activeAzureProfile }),
           azure.status == .connected {
            return true
        }
        if !activeKubeContext.isEmpty,
           let kube = profiles.first(where: { $0.provider == .kubernetes && $0.name == activeKubeContext }),
           kube.status == .connected {
            return true
        }
        return false
    }

    public var activeIdentityStatusLabel: String {
        var connectedLabels: [String] = []
        if activeProfile(for: .aws) != nil { connectedLabels.append("AWS") }
        if activeProfile(for: .gcp) != nil { connectedLabels.append("GCP") }
        if activeProfile(for: .azure) != nil { connectedLabels.append("Azure") }
        if activeProfile(for: .kubernetes) != nil { connectedLabels.append("K8s") }

        if !connectedLabels.isEmpty {
            return connectedLabels.joined(separator: " · ") + " Connected"
        }
        return "Local User"
    }
}
