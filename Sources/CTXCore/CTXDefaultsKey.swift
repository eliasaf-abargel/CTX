import Foundation

/// The `UserDefaults` keys backing CTX's overridable config-file locations.
///
/// The settings UI writes these and the parsers read them, so they lived as
/// duplicated string literals on both sides — a typo in either place silently
/// split the pair and the override stopped taking effect.
public enum CTXDefaultsKey {
    public static let awsConfigPath = "customAWSConfigPath"
    public static let awsCredentialsPath = "customAWSCredentialsPath"
    public static let gcpConfigDirPath = "customGCPConfigDirPath"
    public static let azureProfilesDirPath = "customAzureProfilesDirPath"
    public static let azureCLIDirPath = "customAzureCLIDirPath"
    public static let kubeconfigPath = "customKubeconfigPath"
}
