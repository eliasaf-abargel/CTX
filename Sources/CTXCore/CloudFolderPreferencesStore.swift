import Foundation

public struct CloudFolderState: Sendable {
    public var customFolders: [CloudFolder]
    public var folderCustomizations: [String: CloudFolder]
    public var folderOverrides: [String: String]
    public var hiddenFolderIDs: Set<String>

    public init(
        customFolders: [CloudFolder] = [],
        folderCustomizations: [String: CloudFolder] = [:],
        folderOverrides: [String: String] = [:],
        hiddenFolderIDs: Set<String> = []
    ) {
        self.customFolders = customFolders
        self.folderCustomizations = folderCustomizations
        self.folderOverrides = folderOverrides
        self.hiddenFolderIDs = hiddenFolderIDs
    }
}

public final class CloudFolderPreferencesStore {
    private let defaults: UserDefaults
    private let folderOverridesKey: String
    private let customFoldersKey: String
    private let folderCustomizationsKey: String
    private let hiddenFolderIDsKey: String

    public init(
        defaults: UserDefaults = .standard,
        folderOverridesKey: String = "profileFolderOverrides",
        customFoldersKey: String = "customFolders",
        folderCustomizationsKey: String = "folderCustomizations",
        hiddenFolderIDsKey: String = "hiddenFolderIDs"
    ) {
        self.defaults = defaults
        self.folderOverridesKey = folderOverridesKey
        self.customFoldersKey = customFoldersKey
        self.folderCustomizationsKey = folderCustomizationsKey
        self.hiddenFolderIDsKey = hiddenFolderIDsKey
    }

    public func load() -> CloudFolderState {
        CloudFolderState(
            customFolders: load(customFoldersKey, defaultValue: []),
            folderCustomizations: load(folderCustomizationsKey, defaultValue: [:]),
            folderOverrides: defaults.dictionary(forKey: folderOverridesKey) as? [String: String] ?? [:],
            hiddenFolderIDs: Set(defaults.stringArray(forKey: hiddenFolderIDsKey) ?? [])
        )
    }

    public func saveCustomFolders(_ folders: [CloudFolder]) {
        save(folders, forKey: customFoldersKey)
    }

    public func saveFolderCustomizations(_ customizations: [String: CloudFolder]) {
        save(customizations, forKey: folderCustomizationsKey)
    }

    public func saveFolderOverrides(_ overrides: [String: String]) {
        defaults.set(overrides, forKey: folderOverridesKey)
    }

    public func saveHiddenFolderIDs(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: hiddenFolderIDsKey)
    }

    private func load<T: Decodable>(_ key: String, defaultValue: T) -> T {
        guard let data = defaults.data(forKey: key) else { return defaultValue }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
