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
    @Published public private(set) var profiles: [CloudProfile] = []
    @Published public var selectedSelection: SidebarSelection?
    @Published public private(set) var activeAWSProfile: String
    @Published public private(set) var activeGCPProfile: String
    @Published public private(set) var activeAzureProfile: String
    @Published public private(set) var activeKubeContext: String
    @Published public private(set) var kubernetesContexts: [KubernetesContextProfile] = []
    @Published public private(set) var lastMessage = ""
    @Published public private(set) var lastLoginAt: Date?
    @Published public private(set) var lastVerifiedAt: Date?
    @Published public private(set) var lastCommandDuration: TimeInterval?
    @Published public private(set) var customFolders: [CloudFolder] = []
    @Published public private(set) var folderCustomizations: [String: CloudFolder] = [:]
    @Published public private(set) var folderOverrides: [String: String] = [:]
    @Published public private(set) var hiddenFolderIDs: Set<String> = []
    @Published public var showExpirationWarning = false
    @Published public var connectionErrorMessage: String? = nil
    @Published public var expirationWarningMessage = ""
    @Published public var updateAvailable = false
    @Published public var latestVersionString = ""
    @Published public var isUpdating = false
    @Published public var selectedSettingsTab = 0
    @Published public var isCheckingForUpdates = false
    @Published public var updateCheckMessage = ""
    /// Identity (e.g. SSO email / IAM user) resolved from the active AWS caller-identity.
    @Published public private(set) var awsIdentity = ""
    /// Expiry of the active AWS SSO session, used for the live countdown in the toolbar.
    @Published public private(set) var activeAWSExpiresAt: Date?

    private let configURL: URL
    private let runner: any CloudCommandRunning
    private let kubeConfigMutations: KubeConfigMutationService
    private let kubeConfigDiscoveryService: KubeConfigDiscoveryService
    private let localProfileDiscovery: LocalProfileDiscoveryService
    private let profileCommands: ProfileCommandService
    private let updateService: CTXUpdateService
    private let awsSessionExpirations: AWSSessionExpirationService
    private let notifications: AppNotificationService
    private let awsCredentials: AWSCredentialService
    private let profilePersistence: CloudProfilePersistenceService
    private let fileWatchers: ProfileFileWatcherService
    private let folderPreferences: CloudFolderPreferencesStore
    private var lastExpirationWarningTime: Date?
    private var expirationTimer: AnyCancellable?
    private var lastCacheCheckTime = Date.distantPast
    /// True when the user explicitly clicked X to disconnect GCP — prevents refresh() from
    /// immediately re-activating the profile that is still in ~/.config/gcloud/active_config.
    private var gcpManuallyClearedByUser = false
    private var refreshDebounceTask: Task<Void, Never>?
    private var gcpActiveConfigDebounceTask: Task<Void, Never>?

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

    private func startAllFileWatchers() {
        fileWatchers.start(
            kubeConfigPath: kubeConfigDiscoveryService.candidatePaths().first?.path,
            awsConfigPath: AWSConfigPaths.configURL.path,
            gcpActiveConfigPath: GCPConfigPaths.activeConfigURL.path,
            gcpConfigsDirPath: GCPConfigPaths.configurationsDirURL.path,
            azureProfilesDirPath: AzureConfigPaths.profilesDirURL.path,
            onRefresh: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            },
            onGCPActiveConfigChanged: { [weak self] in
                guard let self else { return }
                self.gcpActiveConfigDebounceTask?.cancel()
                self.gcpActiveConfigDebounceTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    guard !self.gcpManuallyClearedByUser else { return }
                    let activeGCPName = GCPConfigParser.parseActiveConfig()
                    if !activeGCPName.isEmpty && activeGCPName != self.activeGCPProfile {
                        self.activeGCPProfile = activeGCPName
                        UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
                    }
                    self.verifyAllProfiles()
                }
            }
        )
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

    public var groupedProfiles: [ProfileGroup] {
        allFolders.compactMap { folder in
            let matches = profiles.filter {
                $0.provider == folder.provider && self.folder(for: $0).id == folder.id
            }
            if folder.isCustom || !matches.isEmpty {
                return ProfileGroup(folder: folder, profiles: matches)
            }
            return nil
        }
    }

    public var allFolders: [CloudFolder] {
        let builtIn = CloudProvider.allCases.flatMap { provider in
            CloudEnvironment.allCases.map {
                let folder = CloudFolder.builtIn(provider: provider, environment: $0)
                return folderCustomizations[folder.id] ?? folder
            }
        }
        return (builtIn + customFolders).filter { !hiddenFolderIDs.contains($0.id) }
    }

    public func refresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            guard let self else { return }
            
            // Wait 300ms to debounce multiple rapid file updates (e.g. from git, sso logouts, context renames)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            
            // Run heavy filesystem/kubeconfig parsing operations on a background thread
            let discovered = await Task.detached {
                self.localProfileDiscovery.discover()
            }.value
            
            guard !Task.isCancelled else { return }
            
            self.apply(discovered, runVerification: true)
        }
    }

    private func refreshImmediately(runVerification: Bool = true) {
        refreshDebounceTask?.cancel()
        let discovered = localProfileDiscovery.discover()
        apply(discovered, runVerification: runVerification)
    }

    private func apply(_ discovered: LocalProfileDiscoveryResult, runVerification: Bool) {
        kubernetesContexts = discovered.kubernetesContexts
        if !discovered.currentKubeContext.isEmpty {
            activeKubeContext = discovered.currentKubeContext
            UserDefaults.standard.set(discovered.currentKubeContext, forKey: "activeKubeContext")
        }

        profiles = discovered.profiles

        // Only auto-detect active GCP profile if the user hasn't manually disconnected.
        if !gcpManuallyClearedByUser {
            let activeGCPName = discovered.activeGCPProfile
            if !activeGCPName.isEmpty {
                activeGCPProfile = activeGCPName
                UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
            }
        }

        if let selection = selectedSelection, case .profile(let pId) = selection, !profiles.contains(where: { $0.id == pId }) {
            selectedSelection = nil
        }

        let awsCount = profiles.filter { $0.provider == .aws }.count
        let gcpCount = profiles.filter { $0.provider == .gcp }.count
        let kubeCount = profiles.filter { $0.provider == .kubernetes }.count
        lastMessage = "Loaded \(awsCount) AWS profiles, \(gcpCount) GCP configurations and \(kubeCount) Kubernetes contexts"
        if runVerification {
            verifyAllProfiles()
        }
    }

    public func isActive(_ profile: CloudProfile) -> Bool {
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

    private func setActive(_ profile: CloudProfile, runActivation: Bool) {
        selectedSelection = .profile(profile.id)
        switch profile.provider {
        case .aws:
            activeAWSProfile = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeAWSProfile")
            lastMessage = "Active AWS_PROFILE=\(profile.name)"
            
            do {
                try awsCredentials.syncDefaultProfile(from: profile.name)
            } catch {
                lastMessage = "Failed to sync default credentials: \(error.localizedDescription)"
            }
            
            checkAllSessionsExpiration()
        case .gcp:
            gcpManuallyClearedByUser = false   // user is explicitly choosing a profile
            UserDefaults.standard.set(false, forKey: "gcpManuallyClearedByUser")
            activeGCPProfile = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeGCPProfile")
            lastMessage = "Active GCP configuration=\(profile.name)"
            guard runActivation else { return }
            
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
            activeAzureProfile = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeAzureProfile")
            lastMessage = "Active Azure subscription=\(profile.name)"
            guard runActivation else { return }

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
            activeKubeContext = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeKubeContext")
            lastMessage = "Active kube context=\(profile.name)"
            guard runActivation else { return }

            Task {
                let startedAt = Date()
                let result = await kubeConfigMutations.useContext(profile.name)
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

    /// A human label for whoever is currently signed in — the active cloud account,
    /// not the developer. Falls back to the local macOS user when nothing is active.
    public var activeIdentityLabel: String {
        if !activeGCPProfile.isEmpty,
           let gcp = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPProfile }),
           !gcp.roleName.isEmpty {
            return gcp.roleName // GCP account email
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

    /// 1–2 letter monogram derived from `activeIdentityLabel` for the avatar.
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

    public func folder(for profile: CloudProfile) -> CloudFolder {
        if let folderID = folderOverrides[profile.id],
           let folder = allFolders.first(where: { $0.id == folderID }) {
            return folder
        }
        return CloudFolder.builtIn(provider: profile.provider, environment: CloudEnvironment.infer(from: profile))
    }

    public func move(_ profile: CloudProfile, to folder: CloudFolder) {
        folderOverrides[profile.id] = folder.id
        saveFolderOverrides()
        lastMessage = "Moved \(profile.name) to \(folder.name)"
    }

    public func addFolder(name: String, provider: CloudProvider, icon: CloudFolderIcon) throws {
        let name = try normalizedFolderName(name)
        guard allFolders.contains(where: { $0.provider == provider && $0.name.caseInsensitiveCompare(name) == .orderedSame }) == false else {
            throw AWSConfigWriterError.invalid("folder name")
        }

        customFolders.append(
            CloudFolder(
                id: "\(provider.rawValue):custom:\(UUID().uuidString)",
                provider: provider,
                name: name,
                icon: icon
            )
        )
        saveCustomFolders()
        lastMessage = "Created folder \(name)"
    }

    public func updateFolder(_ folder: CloudFolder, name: String, icon: CloudFolderIcon) throws {
        guard folder.isCustom else {
            let name = try normalizedFolderName(name)
            folderCustomizations[folder.id] = CloudFolder(
                id: folder.id,
                provider: folder.provider,
                name: name,
                icon: icon,
                isCustom: false
            )
            saveFolderCustomizations()
            lastMessage = "Updated folder \(name)"
            return
        }
        guard let index = customFolders.firstIndex(where: { $0.id == folder.id }) else {
            return
        }

        let name = try normalizedFolderName(name)
        customFolders[index].name = name
        customFolders[index].icon = icon
        saveCustomFolders()
        lastMessage = "Updated folder \(name)"
    }

    public func deleteFolder(_ folder: CloudFolder) {
        if folder.isCustom {
            customFolders.removeAll { $0.id == folder.id }
            folderOverrides = folderOverrides.filter { $0.value != folder.id }
            saveCustomFolders()
            saveFolderOverrides()
        } else {
            hiddenFolderIDs.insert(folder.id)
            saveHiddenFolderIDs()
        }
        if case .folder(let fId) = selectedSelection, fId == folder.id {
            if let firstProfile = profiles.first {
                selectedSelection = .profile(firstProfile.id)
            } else {
                selectedSelection = nil
            }
        }
        lastMessage = "Deleted folder \(folder.name)"
    }

    public func restoreAllFolders() {
        hiddenFolderIDs.removeAll()
        saveHiddenFolderIDs()
        lastMessage = "Restored all default folders"
    }

    private func saveHiddenFolderIDs() {
        folderPreferences.saveHiddenFolderIDs(hiddenFolderIDs)
    }

    public func login(_ profile: CloudProfile) {
        setActive(profile, runActivation: false)
        
        // Lookup the fresh status from the store's source of truth to avoid stale struct copies
        if let freshProfile = profiles.first(where: { $0.id == profile.id }),
           freshProfile.status == .connected {
            Task {
                await verify(freshProfile)
            }
            return
        }
        if profile.provider != .kubernetes {
            updateStatus(profile, status: .connecting)
        }
        
        Task {
            let startedAt = Date()
            switch profile.provider {
            case .aws:
                lastMessage = "Starting AWS SSO login for \(profile.name)"
                let result = await profileCommands.login(profile)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                logConnectCall(step: "app_connect", kind: "aws", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "AWS SSO login completed"
                } else {
                    lastMessage = result.output
                    connectionErrorMessage = result.output
                }
            case .gcp:
                gcpManuallyClearedByUser = false   // user is re-connecting, resume auto-detection
                lastMessage = "Starting gcloud auth login for \(profile.name)"
                let result = await profileCommands.login(profile)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                logConnectCall(step: "app_connect", kind: "gcp", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "GCP auth login completed"
                } else {
                    lastMessage = result.output
                    connectionErrorMessage = result.output
                }
            case .azure:
                lastMessage = "Starting az login for \(profile.name)"
                let result = await profileCommands.login(profile)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                logConnectCall(step: "app_connect", kind: "azure", profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "Azure login completed"
                    if !profile.accountID.isEmpty {
                        _ = await profileCommands.selectAzureSubscription(profile)
                    }
                } else {
                    lastMessage = result.output
                    connectionErrorMessage = result.output
                }
            case .kubernetes:
                lastMessage = "Kubernetes context \(profile.name) selected"
            }
            await verify(profile)
        }
    }

    public func logout(_ profile: CloudProfile) {
        switch profile.provider {
        case .aws:
            updateStatus(profile, status: .disconnecting)
            if activeAWSProfile == profile.name {
                clearActive(for: .aws)
            }
            Task {
                lastMessage = "Logging out AWS profile \(profile.name)..."
                let result = await profileCommands.logout(profile)
                updateStatus(profile, status: result.exitCode == 0 ? .needsLogin : status(for: result))
                refresh()
            }
        case .gcp:
            updateStatus(profile, status: .disconnecting)
            if activeGCPProfile == profile.name {
                clearActive(for: .gcp)
            }
            Task {
                lastMessage = "Revoking GCP configuration \(profile.name)..."
                let result = await profileCommands.logout(profile)
                updateStatus(profile, status: result.exitCode == 0 ? .needsLogin : status(for: result))
                refresh()
            }
        case .azure:
            updateStatus(profile, status: .disconnecting)
            if activeAzureProfile == profile.name {
                clearActive(for: .azure)
            }
            Task {
                lastMessage = "Signing out Azure \(profile.name)..."
                let result = await profileCommands.logout(profile)
                updateStatus(profile, status: result.exitCode == 0 ? .needsLogin : status(for: result))
                refresh()
            }
        case .kubernetes:
            if activeKubeContext == profile.name {
                clearActive(for: .kubernetes)
            }
            Task {
                lastMessage = "Cleared current kube context"
                _ = await kubeConfigMutations.clearCurrentContext()
                refresh()
            }
        }
    }

    public func verify(_ profile: CloudProfile) async {
        let startedAt = Date()
        let result = await profileCommands.verify(profile, activeKubeContext: activeKubeContext)
        lastCommandDuration = Date().timeIntervalSince(startedAt)
        let step = profile.provider == .kubernetes ? "verify_kubectl" : "app_connect"
        logConnectCall(step: step, kind: profile.provider.rawValue.lowercased(), profileID: profile.id, started: startedAt, outcome: result.exitCode == 0 ? "success" : "failure")

        let isConnected = result.exitCode == 0
        let oldStatus = profiles.first(where: { $0.id == profile.id })?.status ?? .unknown
        
        if isConnected {
            lastVerifiedAt = Date()
            if profile.provider == .aws {
                if profile.name == activeAWSProfile,
                   let identity = awsCredentials.identity(fromCallerIdentityOutput: result.output) {
                    awsIdentity = identity
                }
                await fetchAndStoreCredentials(for: profile)
            }
            
            // Auto-activate profile if:
            // 1. It transitioned from disconnected to connected (user logged in independently on CLI)
            // 2. The app just started (oldStatus == .unknown) and no active profile is set yet
            let activeName: String
            switch profile.provider {
            case .aws: activeName = activeAWSProfile
            case .gcp: activeName = activeGCPProfile
            case .azure: activeName = activeAzureProfile
            case .kubernetes: activeName = activeKubeContext
            }
            if oldStatus != .connected {
                if oldStatus != .unknown {
                    // Only auto-activate if the current active profile is empty or matches this profile,
                    // OR if the current active profile is not connected and this profile is the one selected in the UI.
                    if activeName.isEmpty || activeName == profile.name {
                        setActive(profile)
                    } else if let activeProf = profiles.first(where: { $0.provider == profile.provider && $0.name == activeName }),
                              activeProf.status != .connected {
                        if case .profile(let pId) = selectedSelection, profile.id == pId {
                            setActive(profile)
                        }
                    }
                } else if activeName.isEmpty {
                    setActive(profile)
                }
            }
        }
        
        let newStatus: ProfileStatus
        if isConnected {
            newStatus = .connected
        } else if profile.provider == .kubernetes {
            newStatus = .unknown
        } else {
            newStatus = status(for: result)
        }
        
        updateStatus(profile, status: newStatus)
    }

    public func addAWSProfile(_ draft: AWSProfileDraft, targetFolder: CloudFolder? = nil) throws {
        try profilePersistence.addAWSProfile(draft)
        let profileName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetFolder, targetFolder.provider == .aws {
            folderOverrides[CloudProfile(provider: .aws, name: profileName).id] = targetFolder.id
            saveFolderOverrides()
        }
        refreshImmediately()
        if let profile = profiles.first(where: { $0.provider == .aws && $0.name == profileName }) {
            setActive(profile)
        }
    }

    public func updateAWSProfile(_ profile: CloudProfile, draft: AWSProfileDraft) throws {
        try profilePersistence.updateAWSProfile(originalName: profile.name, draft: draft)
        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refreshImmediately()
        if let updated = profiles.first(where: { $0.provider == .aws && $0.name == draft.name }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteAWSProfile(_ profile: CloudProfile) throws {
        try profilePersistence.deleteAWSProfile(profile.name)
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if activeAWSProfile == profile.name {
            clearActive()
        }
        refreshImmediately()
        lastMessage = "Deleted \(profile.name)"
    }

    public func addGCPProfile(_ draft: GCPProfileDraft, targetFolder: CloudFolder? = nil) throws {
        try profilePersistence.addGCPProfile(draft)
        let profileName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetFolder, targetFolder.provider == .gcp {
            folderOverrides[CloudProfile(provider: .gcp, name: profileName).id] = targetFolder.id
            saveFolderOverrides()
        }
        refreshImmediately()
        if let profile = profiles.first(where: { $0.provider == .gcp && $0.name == profileName }) {
            setActive(profile)
        }
    }

    public func updateGCPProfile(_ profile: CloudProfile, draft: GCPProfileDraft) throws {
        try profilePersistence.updateGCPProfile(originalName: profile.name, draft: draft)
        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refreshImmediately()
        if let updated = profiles.first(where: { $0.provider == .gcp && $0.name == draft.name }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteGCPProfile(_ profile: CloudProfile) throws {
        try profilePersistence.deleteGCPProfile(profile.name)
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if activeGCPProfile == profile.name {
            clearActive(for: .gcp)
        }
        refreshImmediately()
        lastMessage = "Deleted \(profile.name)"
    }

    public func addAzureProfile(_ draft: AzureProfileDraft, targetFolder: CloudFolder? = nil) throws {
        try profilePersistence.addAzureProfile(draft)
        let profileName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetFolder, targetFolder.provider == .azure {
            folderOverrides[CloudProfile(provider: .azure, name: profileName).id] = targetFolder.id
            saveFolderOverrides()
        }
        refreshImmediately()
        if let profile = profiles.first(where: { $0.provider == .azure && $0.name == profileName }) {
            setActive(profile)
        }
    }

    public func updateAzureProfile(_ profile: CloudProfile, draft: AzureProfileDraft) throws {
        try profilePersistence.updateAzureProfile(originalName: profile.name, draft: draft)
        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refreshImmediately()
        if let updated = profiles.first(where: { $0.provider == .azure && $0.name == draft.name }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteAzureProfile(_ profile: CloudProfile) throws {
        try profilePersistence.deleteAzureProfile(profile.name)
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if activeAzureProfile == profile.name {
            clearActive(for: .azure)
        }
        refreshImmediately()
        lastMessage = "Deleted \(profile.name)"
    }

    // MARK: - Kubernetes Context Management

    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?,
        targetFolder: CloudFolder? = nil
    ) async throws {
        try await addKubeContext(
            name: name,
            server: server,
            cluster: cluster,
            user: user,
            namespace: namespace,
            credential: .bearerToken(token),
            targetFolder: targetFolder
        )
    }

    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        credential: KubeConfigCredential,
        targetFolder: CloudFolder? = nil
    ) async throws {
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await kubeConfigMutations.addContext(
            name: profileName,
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            cluster: cluster.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
            credential: credential
        )
        if let targetFolder, targetFolder.provider == .kubernetes {
            folderOverrides[CloudProfile(provider: .kubernetes, name: profileName).id] = targetFolder.id
            saveFolderOverrides()
        }
        refreshImmediately()
        if let profile = profiles.first(where: { $0.provider == .kubernetes && $0.name == profileName }) {
            setActive(profile)
        }
    }

    public func updateKubeContext(
        _ profile: CloudProfile,
        newName: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?
    ) async throws {
        let oldName = profile.name
        try await kubeConfigMutations.updateContext(oldName: oldName, newName: newName, server: server, cluster: cluster, user: user, namespace: namespace, token: token)

        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refreshImmediately()

        if let updated = profiles.first(where: { $0.provider == .kubernetes && $0.name == newName }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteKubeContext(_ profile: CloudProfile) async throws {
        // The resource cache is keyed by `KubernetesContextProfile.id`
        // (kubeconfig path + context name), not `CloudProfile.id` (provider +
        // name) — look up the real one before it's gone from `kubectl config`.
        let cacheContextID = kubernetesContexts.first { $0.contextName == profile.name }?.id

        try await kubeConfigMutations.deleteContext(profile.name)

        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()

        if activeKubeContext == profile.name {
            clearActive(for: .kubernetes)
        }
        refreshImmediately()
        lastMessage = "Deleted context \(profile.name)"

        // A removed context's disk-cached metadata must not resurface if a future
        // context ever reused the same kubeconfig path + name (however unlikely).
        if let cacheContextID {
            Task.detached {
                await SQLiteResourceCache().clearContext(cacheContextID)
            }
        }
    }

    public func resolveKubeServer(for clusterName: String) async -> String {
        await kubeConfigMutations.resolveServer(for: clusterName)
    }

    private func fetchAndStoreCredentials(for profile: CloudProfile) async {
        lastMessage = "Fetching STS credentials for \(profile.name)..."
        let result = await profileCommands.exportAWSCredentials(for: profile)
        if result.exitCode == 0 {
            do {
                let stored = try awsCredentials.storeExportedCredentials(
                    result.output,
                    profileName: profile.name,
                    isActiveProfile: profile.name == activeAWSProfile
                )
                if profile.name == activeAWSProfile {
                    activeAWSExpiresAt = stored.expiresAt
                }
                lastMessage = "STS credentials retrieved & stored in ~/.aws/credentials"
            } catch {
                lastMessage = "Failed to write STS credentials: \(error.localizedDescription)"
            }
        } else {
            lastMessage = "Failed to fetch STS credentials: \(result.output)"
        }
    }

    private func updateStatus(_ profile: CloudProfile, status: ProfileStatus) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index].status = status
        lastMessage = "\(profile.name): \(status.rawValue)"
        checkAllSessionsExpiration()
    }

    private func status(for result: CommandResult) -> ProfileStatus {
        result.exitCode == 127 || result.output.localizedCaseInsensitiveContains("No such file")
            ? .missingCli
            : .needsLogin
    }

    private func saveFolderOverrides() {
        folderPreferences.saveFolderOverrides(folderOverrides)
    }

    private func saveCustomFolders() {
        folderPreferences.saveCustomFolders(customFolders)
    }

    private func saveFolderCustomizations() {
        folderPreferences.saveFolderCustomizations(folderCustomizations)
    }

    private func normalizedFolderName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .newlines) == nil else {
            throw AWSConfigWriterError.invalid("folder name")
        }
        return name
    }

    public func verifyAllProfiles() {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for profile in profiles {
                    group.addTask {
                        await self.verify(profile)
                    }
                }
            }
        }
    }

    private func checkAllSessionsExpiration() {
        let now = Date()
        guard let snapshot = awsSessionExpirations.snapshot(for: profiles) else { return }
        
        // Trigger verification if the cache folder was modified (user logged in via CLI)
        if snapshot.newestCacheModificationDate > lastCacheCheckTime {
            lastCacheCheckTime = snapshot.newestCacheModificationDate
            verifyAllProfiles()
        }
        
        for profile in profiles where profile.provider == .aws {
            guard let expiresAt = snapshot.expiryByProfileName[profile.name] else { continue }
            let timeLeft = expiresAt.timeIntervalSince(now)

            if timeLeft <= 0, profile.status == .connected {
                updateStatus(profile, status: .needsLogin)
            }

            if profile.name == activeAWSProfile {
                activeAWSExpiresAt = expiresAt
                if timeLeft > -10 && timeLeft <= 120 {
                    if lastExpirationWarningTime != expiresAt {
                        let isExpired = timeLeft <= 0
                        triggerExpirationWarning(profileName: profile.name, expired: isExpired)
                        lastExpirationWarningTime = expiresAt
                    }
                }
            }
        }
    }

    public func sessionExpiry(for profile: CloudProfile) -> Date? {
        awsSessionExpirations.sessionExpiry(for: profile)
    }

    private func triggerExpirationWarning(profileName: String, expired: Bool) {
        if expired {
            expirationWarningMessage = "\(profileName): Session Expired"
        } else {
            expirationWarningMessage = "\(profileName): Session Expiring"
        }
        showExpirationWarning = true
        notifications.sendAWSExpiration(profileName: profileName, expired: expired)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.showExpirationWarning = false
        }
    }

    public func checkForUpdates(manual: Bool = false) {
        isCheckingForUpdates = true
        if manual {
            updateCheckMessage = "Checking for updates..."
        }

        Task {
            do {
                let result = try await updateService.checkForUpdates()

                await MainActor.run {
                    self.isCheckingForUpdates = false
                    if result.isUpdateAvailable {
                        let wasAvailable = self.updateAvailable
                        self.updateAvailable = true
                        self.latestVersionString = result.tagName
                        self.updateCheckMessage = "Update available: \(result.tagName)"
                        if !wasAvailable {
                            self.triggerUpdateNotification(version: result.tagName)
                        }
                        if manual {
                            self.showUpdateAlert(version: result.tagName)
                        }
                    } else {
                        self.updateAvailable = false
                        self.updateCheckMessage = "CTX is up to date."
                        if manual {
                            self.showUpToDateAlert(currentVersion: result.currentVersion)
                        }
                    }
                }
            } catch CTXUpdateServiceError.invalidReleaseInfo {
                await MainActor.run {
                    self.isCheckingForUpdates = false
                    self.updateCheckMessage = "Failed to parse release info."
                    if manual {
                        self.showErrorAlert(message: "Failed to parse release information from GitHub.")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCheckingForUpdates = false
                    self.updateCheckMessage = "Error checking for updates."
                    if manual {
                        self.showErrorAlert(message: "Could not connect to GitHub. Please check your internet connection and try again.")
                    }
                }
            }
        }
    }

    private func showUpToDateAlert(currentVersion: String) {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "CTX \(currentVersion) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }

    private func showUpdateAlert(version: String) {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "Update Available!"
        alert.informativeText = "A new version (\(version)) of CTX is available. Would you like to install it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            self.installUpdate()
        }
        #endif
    }

    private func showErrorAlert(message: String) {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "Update Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }

    private func triggerUpdateNotification(version: String) {
        notifications.sendUpdateAvailable(version: version)
    }

    public func installUpdate() {
        guard !latestVersionString.isEmpty else { return }
        
        isUpdating = true
        let tagName = latestVersionString
        
        lastMessage = "Downloading CTX update \(tagName)..."
        
        Task {
            do {
                await MainActor.run {
                    self.lastMessage = "Installing update..."
                }
                try await updateService.install(tagName: tagName, targetBundlePath: Bundle.main.bundlePath)
                
                #if canImport(AppKit)
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                #else
                exit(0)
                #endif
            } catch {
                await MainActor.run {
                    self.isUpdating = false
                    self.lastMessage = "Update failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func logConnectCall(step: String, kind: String, profileID: String, started: Date, outcome: String) {
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
}
