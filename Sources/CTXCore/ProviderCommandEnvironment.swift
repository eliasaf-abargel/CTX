import Foundation

public enum ProviderCommandEnvironment {
    public static func overrides(defaults: UserDefaults = .standard) -> [String: String] {
        var environment: [String: String] = [:]
        add(CTXDefaultsKey.awsConfigPath, as: "AWS_CONFIG_FILE", from: defaults, to: &environment)
        add(CTXDefaultsKey.awsCredentialsPath, as: "AWS_SHARED_CREDENTIALS_FILE", from: defaults, to: &environment)
        add(CTXDefaultsKey.gcpConfigDirPath, as: "CLOUDSDK_CONFIG", from: defaults, to: &environment)
        add(CTXDefaultsKey.azureCLIDirPath, as: "AZURE_CONFIG_DIR", from: defaults, to: &environment)
        return environment
    }

    private static func add(
        _ defaultsKey: String,
        as environmentKey: String,
        from defaults: UserDefaults,
        to environment: inout [String: String]
    ) {
        guard let value = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return
        }
        environment[environmentKey] = value
    }
}
