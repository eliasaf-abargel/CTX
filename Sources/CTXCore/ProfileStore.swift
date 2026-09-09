import Combine
import Foundation

private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public internal(set) var presentation: ProfilePresentation?
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
    @Published public var verificationErrors: [String: String] = [:]
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
    @Published public internal(set) var availableAWSRoles: [String: [String]] = [:]

    internal let configURL: URL
    /// Where the selection is recorded for shells started outside CTX.
    ///
    /// `nil` by default so nothing writes to a person's home directory unless the app
    /// explicitly opts in. A store built by a test, or by any other caller, records
    /// nothing - the previous default let the test suite overwrite the real file.
    internal let shellSelectionURL: URL?
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
    /// Where the active-profile selections are remembered. Injectable so a test can
    /// run against a scratch suite instead of the user's real preferences.
    internal let defaults: UserDefaults
    internal var manuallyDisconnectedProfiles: Set<String> = []
    internal var lastExpirationWarningTime: Date?
    internal var expirationTimer: AnyCancellable?
    internal var lastCacheCheckTime = Date.distantPast
    internal var isCheckingSessionExpiration = false
    internal var verificationTask: Task<Void, Never>?
    internal var pendingVerificationRequest = false
    internal var refreshDebounceTask: Task<Void, Never>?
    internal var gcpActiveConfigDebounceTask: Task<Void, Never>?
    internal var expirationWarningTask: Task<Void, Never>?
    internal var profileOperations: [String: ProfileLifecycleOperation] = [:]
    internal var pendingKubeContextActivation: KubeContextActivationIntent?
    internal var deferredPresentation: DeferredProfilePresentation?
    internal let brokerPollDelay: @Sendable () async throws -> Void
    internal let backgroundServicesEnabled: Bool

    @Published public internal(set) var allFolders: [CloudFolder] = []
    @Published public internal(set) var groupedProfiles: [ProfileGroup] = []
    internal var folderIndex: [String: CloudFolder] = [:]
    internal var foldersByProvider: [CloudProvider: [CloudFolder]] = [:]

    public init(
        configURL: URL = AWSConfigPaths.configURL,
        shellSelectionURL: URL? = nil,
        runner: any CloudCommandRunning = CloudCommandRunner(),
        kubeConfigMutations: KubeConfigMutationService? = nil,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService? = nil,
        localProfileDiscovery: LocalProfileDiscoveryService? = nil,
        profileCommands: ProfileCommandService? = nil,
        updateService: CTXUpdateService? = nil,
        awsSessionExpirations: AWSSessionExpirationService = AWSSessionExpirationService(),
        notifications: AppNotificationService = AppNotificationService(),
        awsCredentials: AWSCredentialService? = nil,
        profilePersistence: CloudProfilePersistenceService? = nil,
        fileWatchers: ProfileFileWatcherService = ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore = CloudFolderPreferencesStore(),
        missingCLIToolResolver: @escaping MissingCLIToolResolving = { CLITool.firstMissing(for: $0) },
        brokerPollDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        },
        defaults: UserDefaults = .standard,
        startsBackgroundServices: Bool = true
    ) {
        let sendableDefaults = SendableUserDefaults(defaults)
        let resolvedKubeDiscovery = kubeConfigDiscoveryService ?? KubeConfigDiscoveryService(
            customPath: {
                sendableDefaults.value.string(forKey: CTXDefaultsKey.kubeconfigPath)
            }
        )
        let providerEnvironment: @Sendable () -> [String: String] = {
            ProviderCommandEnvironment.overrides(defaults: sendableDefaults.value)
        }
        self.configURL = configURL
        self.shellSelectionURL = shellSelectionURL
        self.runner = runner
        self.kubeConfigMutations = kubeConfigMutations ?? KubeConfigMutationService(
            providerEnvironment: providerEnvironment
        )
        self.kubeConfigDiscoveryService = resolvedKubeDiscovery
        self.localProfileDiscovery = localProfileDiscovery
            ?? LocalProfileDiscoveryService(
                awsConfigURL: {
                    Self.configuredURL(
                        defaultsKey: CTXDefaultsKey.awsConfigPath,
                        fallback: configURL,
                        defaults: sendableDefaults.value
                    )
                },
                kubeConfigDiscoveryService: resolvedKubeDiscovery
            )
        self.profileCommands = profileCommands ?? ProfileCommandService(
            runner: runner,
            providerEnvironment: providerEnvironment
        )
        self.updateService = updateService ?? CTXUpdateService(runner: runner)
        self.awsSessionExpirations = awsSessionExpirations
        self.notifications = notifications
        self.awsCredentials = awsCredentials ?? AWSCredentialService(
            configURLProvider: {
                Self.configuredURL(
                    defaultsKey: CTXDefaultsKey.awsConfigPath,
                    fallback: configURL,
                    defaults: sendableDefaults.value
                )
            },
            credentialsURLProvider: {
                Self.configuredURL(
                    defaultsKey: CTXDefaultsKey.awsCredentialsPath,
                    fallback: AWSConfigPaths.credentialsURL,
                    defaults: sendableDefaults.value
                )
            }
        )
        self.profilePersistence = profilePersistence ?? CloudProfilePersistenceService(awsConfigURL: configURL)
        self.fileWatchers = fileWatchers
        self.folderPreferences = folderPreferences
        self.missingCLIToolResolver = missingCLIToolResolver
        self.brokerPollDelay = brokerPollDelay
        self.backgroundServicesEnabled = startsBackgroundServices
        self.defaults = defaults
        self.manuallyDisconnectedProfiles = Set(
            defaults.stringArray(forKey: CTXDefaultsKey.manuallyDisconnectedProfileIDs) ?? []
        )
        self.activeAWSProfile = defaults.string(forKey: "activeAWSProfile") ?? ""
        self.activeGCPProfile = defaults.string(forKey: "activeGCPProfile") ?? ""
        self.activeAzureProfile = defaults.string(forKey: "activeAzureProfile") ?? ""
        self.activeKubeContext = defaults.string(forKey: "activeKubeContext") ?? ""
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

        // Record what was just restored. Doing this only when the selection changes
        // left a person whose profile was already active with no file at all, so
        // terminals opened by hand adopted nothing until they toggled something.
        recordShellSelection()
    }

    public var selectedProfile: CloudProfile? {
        if case .profile(let profileID) = selectedSelection {
            return profiles.first { $0.id == profileID }
        }
        return nil
    }

    nonisolated static func configuredURL(
        defaultsKey: String,
        fallback: URL,
        defaults: UserDefaults
    ) -> URL {
        guard let path = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            return fallback
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    public var selectedFolder: CloudFolder? {
        if case .folder(let folderID) = selectedSelection {
            return allFolders.first { $0.id == folderID }
        }
        return nil
    }
}
