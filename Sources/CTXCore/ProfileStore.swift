import Combine
import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [CloudProfile] = []
    @Published public var selectedSelection: SidebarSelection?
    @Published public private(set) var activeAWSProfile: String
    @Published public private(set) var activeGCPProfile: String
    @Published public private(set) var lastMessage = ""
    @Published public private(set) var lastLoginAt: Date?
    @Published public private(set) var lastVerifiedAt: Date?
    @Published public private(set) var lastCommandDuration: TimeInterval?
    @Published public private(set) var customFolders: [CloudFolder] = []
    @Published public private(set) var folderCustomizations: [String: CloudFolder] = [:]
    @Published public private(set) var folderOverrides: [String: String] = [:]
    @Published public private(set) var hiddenFolderIDs: Set<String> = []
    @Published public var showExpirationWarning = false
    @Published public var expirationWarningMessage = ""
    @Published public var updateAvailable = false
    @Published public var latestVersionString = ""
    @Published public var isUpdating = false
    @Published public var selectedSettingsTab = 0

    private let configURL: URL
    private let runner: CloudCommandRunner
    private let folderOverridesKey = "profileFolderOverrides"
    private let customFoldersKey = "customFolders"
    private let folderCustomizationsKey = "folderCustomizations"
    private var lastExpirationWarningTime: Date?
    private var expirationTimer: AnyCancellable?
    private var lastCacheCheckTime = Date.distantPast

    public init(
        configURL: URL = AWSConfigPaths.configURL,
        runner: CloudCommandRunner = CloudCommandRunner()
    ) {
        self.configURL = configURL
        self.runner = runner
        self.activeAWSProfile = UserDefaults.standard.string(forKey: "activeAWSProfile") ?? ""
        self.activeGCPProfile = UserDefaults.standard.string(forKey: "activeGCPProfile") ?? ""
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
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        checkForUpdates()
        
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForUpdates()
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
        
        self.profiles = loadedProfiles
        
        let activeGCPName = GCPConfigParser.parseActiveConfig()
        if !activeGCPName.isEmpty {
            self.activeGCPProfile = activeGCPName
            UserDefaults.standard.set(activeGCPName, forKey: "activeGCPProfile")
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
        }
    }

    public func setActive(_ profile: CloudProfile) {
        selectedSelection = .profile(profile.id)
        if profile.provider == .aws {
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
        } else {
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
        }
    }

    public func clearActive(for provider: CloudProvider) {
        switch provider {
        case .aws:
            activeAWSProfile = ""
            UserDefaults.standard.removeObject(forKey: "activeAWSProfile")
            lastMessage = "No active AWS profile"
            do {
                try AWSConfigWriter.deleteSection("default", from: AWSConfigPaths.configURL)
                try AWSConfigWriter.deleteSection("default", from: AWSConfigPaths.credentialsURL)
            } catch {
                // Ignore clearing errors
            }
        case .gcp:
            activeGCPProfile = ""
            UserDefaults.standard.removeObject(forKey: "activeGCPProfile")
            lastMessage = "No active GCP configuration"
        }
        showExpirationWarning = false
    }

    public func clearActive() {
        clearActive(for: .aws)
    }

    public func report(_ message: String) {
        lastMessage = message
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
            if profile.provider == .aws {
                lastMessage = "Starting AWS SSO login for \(profile.name)"
                let result = await runner.run(["aws", "sso", "login", "--profile", profile.name])
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "AWS SSO login completed"
                } else {
                    lastMessage = result.output
                }
            } else {
                lastMessage = "Starting gcloud auth login for \(profile.name)"
                let result = await runner.run(["gcloud", "auth", "login", "--update-adc", "--configuration", profile.name])
                lastCommandDuration = Date().timeIntervalSince(startedAt)
                if result.exitCode == 0 {
                    lastLoginAt = Date()
                    lastMessage = "GCP auth login completed"
                } else {
                    lastMessage = result.output
                }
            }
            await verify(profile)
        }
    }

    public func logout(_ profile: CloudProfile) {
        if profile.provider == .aws {
            if activeAWSProfile == profile.name {
                clearActive(for: .aws)
            }
            Task {
                lastMessage = "Logging out AWS profile \(profile.name)..."
                _ = await runner.run(["aws", "sso", "logout", "--profile", profile.name])
                refresh()
            }
        } else {
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
        }
    }

    public func verify(_ profile: CloudProfile) async {
        let startedAt = Date()
        let result: CommandResult
        if profile.provider == .aws {
            result = await runner.run([
                "aws", "sts", "get-caller-identity",
                "--profile", profile.name,
                "--output", "json"
            ])
        } else {
            result = await runner.run([
                "gcloud", "auth", "print-access-token",
                "--configuration", profile.name
            ])
        }
        lastCommandDuration = Date().timeIntervalSince(startedAt)
        
        let isConnected = result.exitCode == 0
        let oldStatus = profiles.first(where: { $0.id == profile.id })?.status ?? .unknown
        
        if isConnected {
            lastVerifiedAt = Date()
            if profile.provider == .aws {
                await fetchAndStoreCredentials(for: profile)
            }
            
            // Auto-activate profile if:
            // 1. It transitioned from disconnected to connected (user logged in independently on CLI)
            // 2. The app just started (oldStatus == .unknown) and no active profile is set yet
            let activeName = profile.provider == .aws ? activeAWSProfile : activeGCPProfile
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
        
        updateStatus(
            profile,
            status: isConnected ? .connected : status(for: result)
        )
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
                    
                    try AWSConfigWriter.updateCredentials(
                        profileName: profile.name,
                        accessKeyId: accessKeyId,
                        secretAccessKey: secretAccessKey,
                        sessionToken: sessionToken
                    )
                    if profile.name == activeAWSProfile {
                        try AWSConfigWriter.copyConfig(from: profile.name, to: "default")
                        try AWSConfigWriter.updateCredentials(
                            profileName: "default",
                            accessKeyId: accessKeyId,
                            secretAccessKey: secretAccessKey,
                            sessionToken: sessionToken
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
        
        for profile in profiles {
            guard !profile.ssoStartURL.isEmpty else { continue }
            let normalizedStartUrl = profile.ssoStartURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            if let expiresAt = cachedSessions[normalizedStartUrl] {
                let timeLeft = expiresAt.timeIntervalSince(now)
                
                if timeLeft <= 0 {
                    if profile.status == .connected {
                        updateStatus(profile, status: .needsLogin)
                    }
                }
                
                if profile.name == activeAWSProfile {
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
        
        UNUserNotificationCenter.current().add(request) { _ in }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.showExpirationWarning = false
        }
    }

    public func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/eliasaf-abargel/CTX/releases/latest") else {
            return
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
                    
                    if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                        await MainActor.run {
                            let wasAvailable = self.updateAvailable
                            self.updateAvailable = true
                            self.latestVersionString = tagName
                            if !wasAvailable {
                                self.triggerUpdateNotification(version: tagName)
                            }
                        }
                    }
                }
            } catch {
                // Ignore background check errors silently
            }
        }
    }

    private func triggerUpdateNotification(version: String) {
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
