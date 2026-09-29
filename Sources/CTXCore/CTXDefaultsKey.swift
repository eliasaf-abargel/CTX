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
    /// Whether the first-launch onboarding tour has been shown (or skipped).
    /// Versioned so a future tour covering new features can run again for
    /// everyone, without re-showing the parts people already saw.
    public static let hasCompletedOnboardingTourV1 = "hasCompletedOnboardingTourV1"
    /// Whether the MCP server's `ctx_apply_yaml` tool is allowed to mutate a live
    /// cluster on behalf of a connected AI client. Off by default — an external
    /// agent must not be able to apply changes until a person opts in explicitly
    /// in Settings. `ctx_dry_run_yaml` is unaffected; dry-run never mutates.
    public static let mcpApplyEnabled = "mcpApplyEnabled"
}
