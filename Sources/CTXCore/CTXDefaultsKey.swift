import Foundation

/// Shared `UserDefaults` keys used across CTX core and settings.
public enum CTXDefaultsKey {
    public static let awsConfigPath = "customAWSConfigPath"
    public static let awsCredentialsPath = "customAWSCredentialsPath"
    public static let gcpConfigDirPath = "customGCPConfigDirPath"
    public static let azureProfilesDirPath = "customAzureProfilesDirPath"
    public static let azureCLIDirPath = "customAzureCLIDirPath"
    public static let kubeconfigPath = "customKubeconfigPath"
    public static let manuallyDisconnectedProfileIDs = "manuallyDisconnectedProfileIDs"
    /// Bundle path of the terminal to open, or empty for whichever is installed.
    public static let terminalApplication = "terminalApplication"
}
