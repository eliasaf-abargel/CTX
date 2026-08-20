import Combine
import Foundation

extension ProfileStore {
    public func folders(for provider: CloudProvider) -> [CloudFolder] {
        foldersByProvider[provider] ?? []
    }

    /// Call after any change to the folder definitions themselves.
    internal func rebuildFolders() {
        let builtIn = CloudProvider.allCases.flatMap { provider in
            CloudEnvironment.allCases.map {
                let folder = CloudFolder.builtIn(provider: provider, environment: $0)
                return folderCustomizations[folder.id] ?? folder
            }
        }
        allFolders = (builtIn + customFolders).filter { !hiddenFolderIDs.contains($0.id) }
        folderIndex = Dictionary(allFolders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        foldersByProvider = Dictionary(grouping: allFolders, by: \.provider)
        rebuildGroupedProfiles()
    }

    /// One pass over the profiles, bucketed by folder, instead of a scan of every
    /// profile for every folder.
    internal func rebuildGroupedProfiles() {
        var buckets: [String: [CloudProfile]] = [:]
        for profile in profiles {
            buckets[folder(for: profile).id, default: []].append(profile)
        }
        groupedProfiles = allFolders.compactMap { folder in
            let matches = buckets[folder.id] ?? []
            guard folder.isCustom || !matches.isEmpty else { return nil }
            return ProfileGroup(folder: folder, profiles: matches)
        }
    }

    public func folder(for profile: CloudProfile) -> CloudFolder {
        if let folderID = folderOverrides[profile.id],
           let folder = folderIndex[folderID],
           folder.provider == profile.provider {
            return folder
        }
        let builtIn = CloudFolder.builtIn(provider: profile.provider, environment: CloudEnvironment.infer(from: profile))
        return folderIndex[builtIn.id] ?? builtIn
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

    internal func saveHiddenFolderIDs() {
        folderPreferences.saveHiddenFolderIDs(hiddenFolderIDs)
    }

    internal func saveFolderOverrides() {
        folderPreferences.saveFolderOverrides(folderOverrides)
    }

    internal func saveCustomFolders() {
        folderPreferences.saveCustomFolders(customFolders)
    }

    internal func saveFolderCustomizations() {
        folderPreferences.saveFolderCustomizations(folderCustomizations)
    }

    internal func promptForFolderIfUnassigned(_ profile: CloudProfile, targetFolder: CloudFolder?) {
        guard targetFolder == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pendingFolderPrompt = profile
        }
    }

    internal func assignFolder(_ folder: CloudFolder?, provider: CloudProvider, profileName: String) {
        guard let folder, folder.provider == provider else { return }
        folderOverrides[CloudProfile(provider: provider, name: profileName).id] = folder.id
        saveFolderOverrides()
    }

    internal func normalizedFolderName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .newlines) == nil else {
            throw AWSConfigWriterError.invalid("folder name")
        }
        return name
    }
}
