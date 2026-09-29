import Foundation

/// A provider CLI that CTX runs as a subprocess, and how a user gets it.
public struct CLITool: Sendable, Identifiable, Hashable {
    public let binary: String
    public let displayName: String
    /// `nil` where the vendor ships no Homebrew package — then the download page
    /// is the only honest answer.
    public let brewPackage: String?
    public let isCask: Bool
    public let downloadPage: URL

    public var id: String { binary }

    public var installCommand: String? {
        guard let brewPackage else { return nil }
        return isCask ? "brew install --cask \(brewPackage)" : "brew install \(brewPackage)"
    }

    public static let aws = CLITool(
        binary: "aws",
        displayName: "AWS CLI",
        brewPackage: "awscli",
        isCask: false,
        downloadPage: URL(string: "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html")!
    )
    public static let gcloud = CLITool(
        binary: "gcloud",
        displayName: "Google Cloud CLI",
        brewPackage: "google-cloud-sdk",
        isCask: true,
        downloadPage: URL(string: "https://cloud.google.com/sdk/docs/install")!
    )
    public static let az = CLITool(
        binary: "az",
        displayName: "Azure CLI",
        brewPackage: "azure-cli",
        isCask: false,
        downloadPage: URL(string: "https://learn.microsoft.com/cli/azure/install-azure-cli-macos")!
    )
    public static let kubectl = CLITool(
        binary: "kubectl",
        displayName: "kubectl",
        brewPackage: "kubernetes-cli",
        isCask: false,
        downloadPage: URL(string: "https://kubernetes.io/docs/tasks/tools/")!
    )
    public static let sdm = CLITool(
        binary: "sdm",
        displayName: "StrongDM (SDM)",
        brewPackage: "sdm",
        isCask: true,
        downloadPage: URL(string: "https://www.strongdm.com/docs/user-guide/client-installation/")!
    )
    public static let tsh = CLITool(
        binary: "tsh",
        displayName: "Teleport CLI",
        brewPackage: "teleport",
        isCask: false,
        downloadPage: URL(string: "https://goteleport.com/docs/installation/")!
    )

    /// What a profile of this shape cannot connect without.
    public static func required(for profile: CloudProfile) -> [CLITool] {
        switch profile.provider {
        case .aws: return [.aws]
        case .gcp: return [.gcloud]
        case .azure: return [.az]
        case .kubernetes:
            var tools: [CLITool] = [.kubectl]
            if profile.usesStrongDM { tools.append(.sdm) }
            if profile.usesTeleport { tools.append(.tsh) }
            return tools
        }
    }

    /// The first required tool that is not on this Mac. Checked before a connect
    /// runs, so a missing CLI reads as "install this" instead of a failed login.
    public static func firstMissing(for profile: CloudProfile) -> CLITool? {
        required(for: profile).first { CLIToolPaths.resolve($0.binary) == nil }
    }

    public static var isHomebrewInstalled: Bool {
        CLIToolPaths.resolve("brew") != nil
    }
}

/// How the connect preflight decides a required CLI is absent. Injected so tests
/// can drive the command flow without depending on which CLIs the host happens to
/// have installed.
public typealias MissingCLIToolResolving = @Sendable (CloudProfile) -> CLITool?

public struct MissingCLIToolRequest: Identifiable, Sendable {
    public let tool: CLITool
    public let profile: CloudProfile

    public init(tool: CLITool, profile: CloudProfile) {
        self.tool = tool
        self.profile = profile
    }

    public var id: String { tool.binary + profile.id }
}
