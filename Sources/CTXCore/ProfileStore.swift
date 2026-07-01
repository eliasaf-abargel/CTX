import Combine
import Foundation
import UserNotifications
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
    private let runner: CloudCommandRunner
    private let folderOverridesKey = "profileFolderOverrides"
    private let customFoldersKey = "customFolders"
    private let folderCustomizationsKey = "folderCustomizations"
    private var lastExpirationWarningTime: Date?
    private var expirationTimer: AnyCancellable?
    private var lastCacheCheckTime = Date.distantPast
    // Kernel-level file watchers so external CLI changes are reflected immediately
    private var kubeConfigSource: DispatchSourceFileSystemObject?
    private var awsConfigSource: DispatchSourceFileSystemObject?
    private var gcpActiveConfigSource: DispatchSourceFileSystemObject?
    private var gcpConfigsDirSource: DispatchSourceFileSystemObject?
    private var azureProfilesDirSource: DispatchSourceFileSystemObject?
    /// True when the user explicitly clicked X to disconnect GCP — prevents refresh() from
    /// immediately re-activating the profile that is still in ~/.config/gcloud/active_config.
    private var gcpManuallyClearedByUser = false

    public init(
        configURL: URL = AWSConfigPaths.configURL,
        runner: CloudCommandRunner = CloudCommandRunner()
    ) {
        self.configURL = configURL
        self.runner = runner
        self.activeAWSProfile = UserDefaults.standard.string(forKey: "activeAWSProfile") ?? ""
        self.activeGCPProfile = UserDefaults.standard.string(forKey: "activeGCPProfile") ?? ""
        self.activeAzureProfile = UserDefaults.standard.string(forKey: "activeAzureProfile") ?? ""
        self.activeKubeContext = UserDefaults.standard.string(forKey: "activeKubeContext") ?? ""
        self.customFolders = Self.loadCustomFolders(key: customFoldersKey)
        self.folderCustomizations = Self.loadFolderCustomizations(key: folderCustomizationsKey)
        self.folderOverrides = Self.loadFolderOverrides(key: folderOverridesKey)
        self.hiddenFolderIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenFolderIDs") ?? [])
        refresh()
        verifyAllProfiles()
        
        self.expirationTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkAllSessionsExpiration()
            }
        
        if Self.canUseNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        checkForUpdates()
        startAllFileWatchers()
        
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForUpdates()
            }
        }
    }

    // MARK: - Real-time file watchers

    /// Creates a DispatchSource that watches a single file path for changes.
    /// Calls `handler` on the utility queue whenever the file is written/renamed/deleted.
    /// Returns the source (which must be retained by the caller) or nil if the file cannot be opened.
    @discardableResult
    private func makeWatcher(
        path: String,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func startAllFileWatchers() {
        startKubeConfigWatcher()
        startAWSConfigWatcher()
        startGCPConfigWatcher()
        startAzureConfigWatcher()
    }

    /// Watches ~/.kube/config – detects kubectl context switches made in any terminal.
    private func startKubeConfigWatcher() {
        kubeConfigSource = makeWatcher(path: KubeConfigPaths.configURL.path) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let text = (try? String(contentsOf: KubeConfigPaths.configURL, encoding: .utf8)) ?? ""
                if !text.isEmpty {
                    let kube = KubeConfigParser.parse(text)
                    if !kube.currentContext.isEmpty && kube.currentContext != self.activeKubeContext {
                        self.activeKubeContext = kube.currentContext
                        UserDefaults.standard.set(kube.currentContext, forKey: "activeKubeContext")
                    }
                }
                self.verifyAllProfiles()
            }
        }
    }

    /// Watches ~/.aws/config – detects aws sso login / profile changes from any terminal.
    private func startAWSConfigWatcher() {
        awsConfigSource = makeWatcher(path: AWSConfigPaths.configURL.path) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
            }
        }
    }

    /// Watches ~/.config/gcloud/active_config and the configurations directory
    /// – detects `gcloud config set` / `gcloud config configurations activate` from any terminal.
    private func startGCPConfigWatcher() {
        gcpActiveConfigSource = makeWatcher(path: GCPConfigPaths.activeConfigURL.path) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Respect user's explicit disconnect — don't override it
                guard !self.gcpManuallyClearedByUser else { return }
                let activeGCPName = GCPConfigParser.parseActiveConfig()
                if !activeGCPName.isEmpty && activeGCPName != self.activeGCPProfile {
                    self.activeGCPProfile = activeGCPName
                    UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
                }
                self.verifyAllProfiles()
            }
        }

        gcpConfigsDirSource = makeWatcher(path: GCPConfigPaths.configurationsDirURL.path) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
            }
        }
    }

    /// Watches ~/.config/ctx/azure/ – detects Azure profile add/remove/edit from any source.
    private func startAzureConfigWatcher() {
        // Ensure the directory exists before trying to watch it
        let dirURL = AzureConfigPaths.profilesDirURL
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        azureProfilesDirSource = makeWatcher(path: dirURL.path) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
            }
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
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var loadedProfiles = AWSConfigParser.parse(text).filter { $0.name != "default" }
        
        let gcpDir = GCPConfigPaths.configurationsDirURL
        if let fileURLs = try? FileManager.default.contentsOfDirectory(at: gcpDir, includingPropertiesForKeys: nil) {
            var gcpProfiles: [CloudProfile] = []
            for fileURL in fileURLs {
                let filename = fileURL.lastPathComponent
                if filename.hasPrefix("config_") {
                    let configName = String(filename.dropFirst("config_".count))
                    if let gcpProfile = GCPConfigParser.parse(contentsOf: fileURL, name: configName) {
                        gcpProfiles.append(gcpProfile)
                    }
                }
            }
            gcpProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadedProfiles.append(contentsOf: gcpProfiles)
        }

        let azureDir = AzureConfigPaths.profilesDirURL
        if let azureURLs = try? FileManager.default.contentsOfDirectory(at: azureDir, includingPropertiesForKeys: nil) {
            var azureProfiles: [CloudProfile] = []
            for fileURL in azureURLs where fileURL.pathExtension == "json" {
                if let azureProfile = AzureConfigParser.parse(contentsOf: fileURL) {
                    azureProfiles.append(azureProfile)
                }
            }
            azureProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadedProfiles.append(contentsOf: azureProfiles)
        }

        let kubeText = (try? String(contentsOf: KubeConfigPaths.configURL, encoding: .utf8)) ?? ""
        if !kubeText.isEmpty {
            let kube = KubeConfigParser.parse(kubeText)
            loadedProfiles.append(contentsOf: kube.contexts)
            if !kube.currentContext.isEmpty {
                self.activeKubeContext = kube.currentContext
                UserDefaults.standard.set(kube.currentContext, forKey: "activeKubeContext")
            }
        }
        
        self.profiles = loadedProfiles
        
        // Only auto-detect active GCP profile if the user hasn't manually disconnected.
        // If the user clicked X in the toolbar, we respect that choice and don't restore it.
        if !gcpManuallyClearedByUser {
            let activeGCPName = GCPConfigParser.parseActiveConfig()
            if !activeGCPName.isEmpty {
                self.activeGCPProfile = activeGCPName
                UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
            }
        }
        
        if let selection = selectedSelection, case .profile(let pId) = selection, !profiles.contains(where: { $0.id == pId }) {
            selectedSelection = nil
        }
        
        let awsCount = profiles.filter { $0.provider == .aws }.count
        let gcpCount = profiles.filter { $0.provider == .gcp }.count
        lastMessage = "Loaded \(awsCount) AWS profiles and \(gcpCount) GCP configurations"
        verifyAllProfiles()
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
        selectedSelection = .profile(profile.id)
        switch profile.provider {
        case .aws:
            activeAWSProfile = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeAWSProfile")
            lastMessage = "Active AWS_PROFILE=\(profile.name)"
            
            do {
                try AWSConfigWriter.copyConfig(from: profile.name, to: "default")
                try AWSConfigWriter.copyCredentials(from: profile.name, to: "default")
            } catch {
                lastMessage = "Failed to sync default credentials: \(error.localizedDescription)"
            }
            
            checkAllSessionsExpiration()
        case .gcp:
            gcpManuallyClearedByUser = false   // user is explicitly choosing a profile
            activeGCPProfile = profile.name
            UserDefaults.standard.set(profile.name, forKey: "activeGCPProfile")
            lastMessage = "Active GCP configuration=\(profile.name)"
            
            Task {
                let startedAt = Date()
                let result = await runner.run(["gcloud", "config", "configurations", "activate", profile.name])
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

            let target = profile.accountID.isEmpty ? profile.name : profile.accountID
            Task {
                let startedAt = Date()
                let result = await runner.run(["az", "account", "set", "--subscription", target])
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

            Task {
                let startedAt = Date()
                let result = await runner.run(["kubectl", "config", "use-context", profile.name])
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
                try AWSConfigWriter.deleteSection("default", from: AWSConfigPaths.configURL)
                try AWSConfigWriter.deleteSection("default", from: AWSConfigPaths.credentialsURL)
            } catch {
                // Ignore clearing errors
            }
        case .gcp:
            gcpManuallyClearedByUser = true
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

    /// Extracts the trailing identity component of an STS/IAM ARN.
    /// `arn:aws:sts::123:assumed-role/Role/maya@acme.io` → `maya@acme.io`.
    private static func identity(fromArn arn: String) -> String? {
        guard let last = arn.split(separator: "/").last else { return nil }
        let value = String(last).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
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
        UserDefaults.standard.set(Array(hiddenFolderIDs), forKey: "hiddenFolderIDs")
    }

    public func login(_ profile: CloudProfile) {
        setActive(profile)
        
        // Lookup the fresh status from the store's source of truth to avoid stale struct copies
        if let freshProfile = profiles.first(where: { $0.id == profile.id }),
           freshProfile.status == .connected {
            Task {
                await verify(freshProfile)
            }
            return
        }
        
        Task {
            let startedAt = Date()
            switch profile.provider {
            case .aws:
                lastMessage = "Starting AWS SSO login for \(profile.name)"
                let result = await runner.run(["aws", "sso", "login", "--profile", profile.name])
                lastCommandDuration = Date().timeIntervalSince(startedAt)
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
                let result = await runner.run(["gcloud", "auth", "login", "--update-adc", "--configuration", profile.name])
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "GCP auth login completed"
                } else {
                    lastMessage = result.output
                    connectionErrorMessage = result.output
                }
            case .azure:
                lastMessage = "Starting az login for \(profile.name)"
                var args = ["az", "login"]
                if !profile.roleName.isEmpty {
                    args.append(contentsOf: ["--tenant", profile.roleName])
                }
                let result = await runner.run(args)
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "Azure login completed"
                    if !profile.accountID.isEmpty {
                        _ = await runner.run(["az", "account", "set", "--subscription", profile.accountID])
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
            if activeAWSProfile == profile.name {
                clearActive(for: .aws)
            }
            Task {
                lastMessage = "Logging out AWS profile \(profile.name)..."
                _ = await runner.run(["aws", "sso", "logout", "--profile", profile.name])
                refresh()
            }
        case .gcp:
            if activeGCPProfile == profile.name {
                clearActive(for: .gcp)
            }
            Task {
                lastMessage = "Revoking GCP configuration \(profile.name)..."
                if !profile.roleName.isEmpty {
                    _ = await runner.run(["gcloud", "auth", "revoke", profile.roleName])
                }
                refresh()
            }
        case .azure:
            if activeAzureProfile == profile.name {
                clearActive(for: .azure)
            }
            Task {
                lastMessage = "Signing out Azure \(profile.name)..."
                _ = await runner.run(["az", "logout"])
                refresh()
            }
        case .kubernetes:
            if activeKubeContext == profile.name {
                clearActive(for: .kubernetes)
            }
            Task {
                lastMessage = "Cleared current kube context"
                _ = await runner.run(["kubectl", "config", "unset", "current-context"])
                refresh()
            }
        }
    }

    public func verify(_ profile: CloudProfile) async {
        let startedAt = Date()
        let result: CommandResult
        switch profile.provider {
        case .aws:
            result = await runner.run([
                "aws", "sts", "get-caller-identity",
                "--profile", profile.name,
                "--output", "json"
            ])
        case .gcp:
            result = await runner.run([
                "gcloud", "auth", "print-access-token",
                "--configuration", profile.name
            ])
        case .azure:
            let target = profile.accountID.isEmpty ? profile.name : profile.accountID
            result = await runner.run([
                "az", "account", "show",
                "--subscription", target,
                "--output", "json"
            ])
        case .kubernetes:
            if profile.name == activeKubeContext {
                result = await runner.run([
                    "kubectl", "config", "get-contexts", profile.name,
                    "--output", "name"
                ])
            } else {
                result = CommandResult(exitCode: 99, output: "Not active context")
            }
        }
        lastCommandDuration = Date().timeIntervalSince(startedAt)
        
        let isConnected = result.exitCode == 0
        let oldStatus = profiles.first(where: { $0.id == profile.id })?.status ?? .unknown
        
        if isConnected {
            lastVerifiedAt = Date()
            if profile.provider == .aws {
                if profile.name == activeAWSProfile,
                   let data = result.output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let arn = json["Arn"] as? String ?? ""
                    let derived = Self.identity(fromArn: arn)
                    awsIdentity = (derived?.isEmpty == false) ? derived! : (json["Account"] as? String ?? "")
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

    public func addAWSProfile(_ draft: AWSProfileDraft) throws {
        try AWSConfigWriter.appendProfile(draft, to: configURL)
        refresh()
        if let profile = profiles.first(where: { $0.name == draft.name }) {
            setActive(profile)
        }
    }

    public func updateAWSProfile(_ profile: CloudProfile, draft: AWSProfileDraft) throws {
        try AWSConfigWriter.updateProfile(originalName: profile.name, draft: draft, to: configURL)
        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refresh()
        if let updated = profiles.first(where: { $0.name == draft.name }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteAWSProfile(_ profile: CloudProfile) throws {
        try AWSConfigWriter.deleteProfile(profile.name, from: configURL)
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if activeAWSProfile == profile.name {
            clearActive()
        }
        refresh()
        lastMessage = "Deleted \(profile.name)"
    }

    public func addGCPProfile(_ draft: GCPProfileDraft) throws {
        try GCPConfigWriter.writeConfig(draft, originalName: nil)
        refresh()
        if let profile = profiles.first(where: { $0.provider == .gcp && $0.name == draft.name }) {
            setActive(profile)
        }
    }

    public func updateGCPProfile(_ profile: CloudProfile, draft: GCPProfileDraft) throws {
        try GCPConfigWriter.writeConfig(draft, originalName: profile.name)
        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refresh()
        if let updated = profiles.first(where: { $0.provider == .gcp && $0.name == draft.name }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteGCPProfile(_ profile: CloudProfile) throws {
        try GCPConfigWriter.deleteConfig(profile.name)
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if activeGCPProfile == profile.name {
            clearActive(for: .gcp)
        }
        refresh()
        lastMessage = "Deleted \(profile.name)"
    }

    public func addAzureProfile(_ draft: AzureProfileDraft) throws {
        try AzureConfigWriter.writeConfig(draft, originalName: nil)
        refresh()
        if let profile = profiles.first(where: { $0.provider == .azure && $0.name == draft.name }) {
            setActive(profile)
        }
    }

    public func updateAzureProfile(_ profile: CloudProfile, draft: AzureProfileDraft) throws {
        try AzureConfigWriter.writeConfig(draft, originalName: profile.name)
        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refresh()
        if let updated = profiles.first(where: { $0.provider == .azure && $0.name == draft.name }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteAzureProfile(_ profile: CloudProfile) throws {
        try AzureConfigWriter.deleteConfig(profile.name)
        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()
        if activeAzureProfile == profile.name {
            clearActive(for: .azure)
        }
        refresh()
        lastMessage = "Deleted \(profile.name)"
    }

    // MARK: - Kubernetes Context Management

    public func addKubeContext(
        name: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        token: String?
    ) async throws {
        let clusterName = cluster.isEmpty ? "\(name)-cluster" : cluster
        let userName = user.isEmpty ? "\(name)-user" : user

        var clusterArgs = [
            "kubectl", "config", "set-cluster", clusterName,
            "--server=\(server)"
        ]
        if server.lowercased().contains("https") {
            clusterArgs.append("--insecure-skip-tls-verify=true")
        }
        let clusterResult = await runner.run(clusterArgs)
        guard clusterResult.exitCode == 0 else {
            throw AWSConfigWriterError.invalid("Failed to configure cluster: \(clusterResult.output)")
        }

        if let token = token, !token.isEmpty {
            let credsResult = await runner.run([
                "kubectl", "config", "set-credentials", userName,
                "--token=\(token)"
            ])
            guard credsResult.exitCode == 0 else {
                throw AWSConfigWriterError.invalid("Failed to configure credentials: \(credsResult.output)")
            }
        }

        var contextArgs = [
            "kubectl", "config", "set-context", name,
            "--cluster=\(clusterName)",
            "--user=\(userName)"
        ]
        if !namespace.isEmpty {
            contextArgs.append("--namespace=\(namespace)")
        }
        let contextResult = await runner.run(contextArgs)
        guard contextResult.exitCode == 0 else {
            throw AWSConfigWriterError.invalid("Failed to configure context: \(contextResult.output)")
        }

        refresh()
        if let profile = profiles.first(where: { $0.provider == .kubernetes && $0.name == name }) {
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

        if oldName != newName {
            let renameResult = await runner.run([
                "kubectl", "config", "rename-context", oldName, newName
            ])
            guard renameResult.exitCode == 0 else {
                throw AWSConfigWriterError.invalid("Failed to rename context: \(renameResult.output)")
            }
        }

        let clusterName = cluster.isEmpty ? "\(newName)-cluster" : cluster
        let userName = user.isEmpty ? "\(newName)-user" : user

        var clusterArgs = [
            "kubectl", "config", "set-cluster", clusterName,
            "--server=\(server)"
        ]
        if server.lowercased().contains("https") {
            clusterArgs.append("--insecure-skip-tls-verify=true")
        }
        let clusterResult = await runner.run(clusterArgs)
        guard clusterResult.exitCode == 0 else {
            throw AWSConfigWriterError.invalid("Failed to update cluster: \(clusterResult.output)")
        }

        if let token = token, !token.isEmpty {
            let credsResult = await runner.run([
                "kubectl", "config", "set-credentials", userName,
                "--token=\(token)"
            ])
            guard credsResult.exitCode == 0 else {
                throw AWSConfigWriterError.invalid("Failed to update credentials: \(credsResult.output)")
            }
        }

        var contextArgs = [
            "kubectl", "config", "set-context", newName,
            "--cluster=\(clusterName)",
            "--user=\(userName)"
        ]
        if !namespace.isEmpty {
            contextArgs.append("--namespace=\(namespace)")
        } else {
            contextArgs.append("--namespace=")
        }
        let contextResult = await runner.run(contextArgs)
        guard contextResult.exitCode == 0 else {
            throw AWSConfigWriterError.invalid("Failed to update context: \(contextResult.output)")
        }

        let oldFolderID = folderOverrides.removeValue(forKey: profile.id)
        refresh()

        if let updated = profiles.first(where: { $0.provider == .kubernetes && $0.name == newName }) {
            if let oldFolderID {
                folderOverrides[updated.id] = oldFolderID
                saveFolderOverrides()
            }
            setActive(updated)
        }
    }

    public func deleteKubeContext(_ profile: CloudProfile) async throws {
        let result = await runner.run([
            "kubectl", "config", "delete-context", profile.name
        ])
        guard result.exitCode == 0 else {
            throw AWSConfigWriterError.invalid("Failed to delete context: \(result.output)")
        }

        folderOverrides.removeValue(forKey: profile.id)
        saveFolderOverrides()

        if activeKubeContext == profile.name {
            clearActive(for: .kubernetes)
        }
        refresh()
        lastMessage = "Deleted context \(profile.name)"
    }

    public func resolveKubeServer(for clusterName: String) async -> String {
        let result = await runner.run([
            "kubectl", "config", "view",
            "-o", "jsonpath={.clusters[?(@.name==\"\(clusterName)\")].cluster.server}"
        ])
        return result.exitCode == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func fetchAndStoreCredentials(for profile: CloudProfile) async {
        lastMessage = "Fetching STS credentials for \(profile.name)..."
        let result = await runner.run([
            "aws", "configure", "export-credentials",
            "--profile", profile.name,
            "--output", "json"
        ])
        if result.exitCode == 0 {
            do {
                if let data = result.output.data(using: .utf8),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let accessKeyId = json["AccessKeyId"] as? String,
                   let secretAccessKey = json["SecretAccessKey"] as? String,
                   let sessionToken = json["SessionToken"] as? String {
                    
                    let expiration = json["Expiration"] as? String
                    
                    try AWSConfigWriter.updateCredentials(
                        profileName: profile.name,
                        accessKeyId: accessKeyId,
                        secretAccessKey: secretAccessKey,
                        sessionToken: sessionToken,
                        expiration: expiration
                    )
                    if profile.name == activeAWSProfile {
                        // Update expiry for the live countdown
                        if let expStr = expiration {
                            let fmt = ISO8601DateFormatter()
                            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            let exp = fmt.date(from: expStr) ?? ISO8601DateFormatter().date(from: expStr)
                            if let exp { activeAWSExpiresAt = exp }
                        }
                        try AWSConfigWriter.copyConfig(from: profile.name, to: "default")
                        try AWSConfigWriter.updateCredentials(
                            profileName: "default",
                            accessKeyId: accessKeyId,
                            secretAccessKey: secretAccessKey,
                            sessionToken: sessionToken,
                            expiration: expiration
                        )
                    }
                    lastMessage = "STS credentials retrieved & stored in ~/.aws/credentials"
                } else {
                    lastMessage = "Failed to parse STS credentials JSON"
                }
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

    private static func loadFolderOverrides(key: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func loadCustomFolders(key: String) -> [CloudFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([CloudFolder].self, from: data)) ?? []
    }

    private static func loadFolderCustomizations(key: String) -> [String: CloudFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CloudFolder].self, from: data)) ?? [:]
    }

    private func saveFolderOverrides() {
        UserDefaults.standard.set(folderOverrides, forKey: folderOverridesKey)
    }

    private func saveCustomFolders() {
        if let data = try? JSONEncoder().encode(customFolders) {
            UserDefaults.standard.set(data, forKey: customFoldersKey)
        }
    }

    private func saveFolderCustomizations() {
        if let data = try? JSONEncoder().encode(folderCustomizations) {
            UserDefaults.standard.set(data, forKey: folderCustomizationsKey)
        }
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
        let fileManager = FileManager.default
        let ssoCacheURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".aws/sso/cache")
        guard let files = try? fileManager.contentsOfDirectory(at: ssoCacheURL, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        
        let now = Date()
        var cachedSessions: [String: Date] = [:]
        var newestModificationDate = Date.distantPast
        
        for fileURL in files where fileURL.pathExtension == "json" {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = resourceValues.contentModificationDate {
                if modDate > newestModificationDate {
                    newestModificationDate = modDate
                }
            }
            
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let startUrl = json["startUrl"] as? String,
                  let expiresAtStr = json["expiresAt"] as? String else {
                continue
            }
            
            let formatter = ISO8601DateFormatter()
            var expiresAt = formatter.date(from: expiresAtStr)
            if expiresAt == nil {
                let fractionalFormatter = ISO8601DateFormatter()
                fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expiresAt = fractionalFormatter.date(from: expiresAtStr)
            }
            
            if let expiresAt {
                let normalizedStartUrl = startUrl.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
                if let existing = cachedSessions[normalizedStartUrl] {
                    if expiresAt > existing {
                        cachedSessions[normalizedStartUrl] = expiresAt
                    }
                } else {
                    cachedSessions[normalizedStartUrl] = expiresAt
                }
            }
        }
        
        // Trigger verification if the cache folder was modified (user logged in via CLI)
        if newestModificationDate > lastCacheCheckTime {
            lastCacheCheckTime = newestModificationDate
            verifyAllProfiles()
        }
        
        for profile in profiles where profile.provider == .aws {
            guard !profile.ssoStartURL.isEmpty else { continue }
            let normalizedStartUrl = profile.ssoStartURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            // Prefer expiry from ~/.aws/credentials (written by fetchAndStoreCredentials)
            // as it reflects the actual STS token lifetime, not the SSO session.
            var resolvedExpiry = cachedSessions[normalizedStartUrl]
            if let credExpStr = Self.credentialsExpiry(for: profile.name) {
                resolvedExpiry = credExpStr
            }
            
            if let expiresAt = resolvedExpiry {
                let timeLeft = expiresAt.timeIntervalSince(now)
                
                if timeLeft <= 0 {
                    if profile.status == .connected {
                        updateStatus(profile, status: .needsLogin)
                    }
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
    }

    /// Reads `aws_session_expiration` from `~/.aws/credentials` for the given profile name.
    private static func credentialsExpiry(for profileName: String) -> Date? {
        guard let text = try? String(contentsOf: AWSConfigPaths.credentialsURL, encoding: .utf8) else { return nil }
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[\(profileName)]" { inSection = true; continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { inSection = false; continue }
            guard inSection else { continue }
            if trimmed.hasPrefix("aws_session_expiration") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let expStr = parts[1].trimmingCharacters(in: .whitespaces)
                let fmtFrac = ISO8601DateFormatter()
                fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = fmtFrac.date(from: expStr) { return d }
                return ISO8601DateFormatter().date(from: expStr)
            }
        }
        return nil
    }

    public func sessionExpiry(for profile: CloudProfile) -> Date? {
        guard profile.provider == .aws else { return nil }
        
        // 1. Check credentials file first
        if let expiry = Self.credentialsExpiry(for: profile.name) {
            return expiry
        }
        
        // 2. Scan sso cache directory
        let ssoDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws")
            .appendingPathComponent("sso")
            .appendingPathComponent("cache")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: ssoDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        
        var latestExpiry: Date? = nil
        let normalizedStartUrl = profile.ssoStartURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        for fileURL in files where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let startUrl = json["startUrl"] as? String,
                  let expiresAtStr = json["expiresAt"] as? String else {
                continue
            }
            
            if startUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedStartUrl {
                let formatter = ISO8601DateFormatter()
                var expiresAt = formatter.date(from: expiresAtStr)
                if expiresAt == nil {
                    let fractionalFormatter = ISO8601DateFormatter()
                    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    expiresAt = fractionalFormatter.date(from: expiresAtStr)
                }
                if let expiresAt {
                    if let current = latestExpiry {
                        if expiresAt > current {
                            latestExpiry = expiresAt
                        }
                    } else {
                        latestExpiry = expiresAt
                    }
                }
            }
        }
        
        return latestExpiry
    }

    private func triggerExpirationWarning(profileName: String, expired: Bool) {
        if expired {
            expirationWarningMessage = "\(profileName): Session Expired"
        } else {
            expirationWarningMessage = "\(profileName): Session Expiring"
        }
        showExpirationWarning = true
        
        let content = UNMutableNotificationContent()
        content.title = expired ? "Session Expired" : "Session Expiring"
        content.body = expired 
            ? "AWS profile \(profileName) session has expired."
            : "AWS profile \(profileName) session expires in 2m."
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(
            identifier: "aws.session.expiration.\(profileName)",
            content: content,
            trigger: nil
        )
        
        if Self.canUseNotifications {
            UNUserNotificationCenter.current().add(request) { _ in }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.showExpirationWarning = false
        }
    }

    public func checkForUpdates(manual: Bool = false) {
        guard let url = URL(string: "https://api.github.com/repos/eliasaf-abargel/CTX/releases/latest") else {
            return
        }
        
        isCheckingForUpdates = true
        if manual {
            updateCheckMessage = "Checking for updates..."
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10.0
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    
                    let latestVersion = tagName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
                    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
                    
                    await MainActor.run {
                        self.isCheckingForUpdates = false
                        if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                            let wasAvailable = self.updateAvailable
                            self.updateAvailable = true
                            self.latestVersionString = tagName
                            self.updateCheckMessage = "Update available: \(tagName)"
                            if !wasAvailable {
                                self.triggerUpdateNotification(version: tagName)
                            }
                            if manual {
                                self.showUpdateAlert(version: tagName)
                            }
                        } else {
                            self.updateAvailable = false
                            self.updateCheckMessage = "CTX is up to date."
                            if manual {
                                self.showUpToDateAlert(currentVersion: currentVersion)
                            }
                        }
                    }
                } else {
                    await MainActor.run {
                        self.isCheckingForUpdates = false
                        self.updateCheckMessage = "Failed to parse release info."
                        if manual {
                            self.showErrorAlert(message: "Failed to parse release information from GitHub.")
                        }
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
        guard Self.canUseNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "A new version \(version) of CTX is available. Click to open Settings and update."
        content.sound = UNNotificationSound.default
        content.userInfo = ["type": "update"]
        
        let request = UNNotificationRequest(
            identifier: "ctx.update.available",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private static var canUseNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public func installUpdate() {
        guard !latestVersionString.isEmpty else { return }
        
        isUpdating = true
        let tagName = latestVersionString
        let downloadURLString = "https://github.com/eliasaf-abargel/CTX/releases/download/\(tagName)/CTX.app.zip"
        
        guard let url = URL(string: downloadURLString) else {
            isUpdating = false
            return
        }
        
        lastMessage = "Downloading CTX update \(tagName)..."
        
        Task {
            do {
                let (tempZipURL, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "CTX", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to download update file"])
                }
                
                let tempDirURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ctx-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
                
                await MainActor.run {
                    self.lastMessage = "Installing update..."
                }
                
                let unzipResult = await runner.run([
                    "unzip", "-q", "-o", tempZipURL.path,
                    "-d", tempDirURL.path
                ])
                
                guard unzipResult.exitCode == 0 else {
                    throw NSError(domain: "CTX", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to extract update package"])
                }
                
                let targetPath = Bundle.main.bundlePath
                let sourcePath = tempDirURL.appendingPathComponent("CTX.app").path
                
                let script = """
                sleep 0.5
                rm -rf "\(targetPath)"
                mv "\(sourcePath)" "\(targetPath)"
                xattr -rd com.apple.quarantine "\(targetPath)" >/dev/null 2>&1 || true
                open "\(targetPath)"
                """
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", script]
                try process.run()
                
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

}
