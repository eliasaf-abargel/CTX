import Foundation

public enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case aws = "AWS"
    case gcp = "GCP"
    case azure = "Azure"
    case kubernetes = "Kubernetes"

    public var systemImage: String {
        switch self {
        case .aws:
            "cloud"
        case .gcp:
            "globe"
        case .azure:
            "triangle"
        case .kubernetes:
            "shippingbox"
        }
    }
}

public enum ProfileStatus: String, Codable, Sendable {
    case unknown = "Unknown"
    case connected = "Connected"
    case needsLogin = "Needs login"
    case missingCli = "Missing CLI"
}

public struct CloudProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(provider.rawValue):\(name)" }

    public var provider: CloudProvider
    public var name: String
    public var accountID: String
    public var roleName: String
    public var region: String
    public var ssoStartURL: String
    public var ssoRegion: String
    public var status: ProfileStatus

    public init(
        provider: CloudProvider,
        name: String,
        accountID: String = "",
        roleName: String = "",
        region: String = "",
        ssoStartURL: String = "",
        ssoRegion: String = "",
        status: ProfileStatus = .unknown
    ) {
        self.provider = provider
        self.name = name
        self.accountID = accountID
        self.roleName = roleName
        self.region = region
        self.ssoStartURL = ssoStartURL
        self.ssoRegion = ssoRegion
        self.status = status
    }

    public var accountLabel: String {
        switch provider {
        case .aws: "AWS Account"
        case .gcp: "GCP Project"
        case .azure: "Azure Subscription"
        case .kubernetes: "Cluster"
        }
    }

    public var roleLabel: String {
        switch provider {
        case .aws: "IAM Role"
        case .gcp: "GCP Account"
        case .azure: "Azure Tenant"
        case .kubernetes: "User"
        }
    }

    public var regionLabel: String {
        switch provider {
        case .aws: "Default Region"
        case .gcp: "Compute Region"
        case .azure: "Default Location"
        case .kubernetes: "Namespace"
        }
    }
}


public enum CloudEnvironment: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case staging = "Staging"
    case development = "Development"
    case admin = "Admin"
    case data = "Data"
    case other = "Other"

    public var id: String { rawValue }

    public var icon: CloudFolderIcon {
        switch self {
        case .production:
            .server
        case .staging:
            .cube
        case .development:
            .tools
        case .admin:
            .admin
        case .data:
            .database
        case .other:
            .folder
        }
    }

    public static func infer(from profile: CloudProfile) -> CloudEnvironment {
        let name = profile.name.lowercased()
        let account = profile.accountID.lowercased()
        if name.contains("redshift") || name.contains("mcp") || name.contains("jdbc") {
            return .data
        }
        if name.contains("prod") || name.hasPrefix("prd") || account.contains("prod") || account.hasPrefix("prd") {
            return .production
        }
        if name.contains("stg") || name.contains("stage") || account.contains("stg") || account.contains("stage") {
            return .staging
        }
        if name.contains("dev") || name.contains("sandbox") || account.contains("dev") || account.contains("sandbox") {
            return .development
        }
        if name.contains("admin") || name.contains("root") || name.hasPrefix("it-") || account.contains("admin") {
            return .admin
        }
        return .other
    }
}

public enum CloudFolderIcon: String, CaseIterable, Identifiable, Codable, Sendable {
    case cloud
    case server
    case cube
    case tools
    case admin
    case database
    case folder
    case shield
    case terminal

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .cloud:
            "cloud"
        case .server:
            "server.rack"
        case .cube:
            "shippingbox"
        case .tools:
            "hammer"
        case .admin:
            "person.badge.key"
        case .database:
            "cylinder.split.1x2"
        case .folder:
            "folder"
        case .shield:
            "shield"
        case .terminal:
            "terminal"
        }
    }
}

public struct CloudFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var provider: CloudProvider
    public var name: String
    public var icon: CloudFolderIcon
    public var isCustom: Bool

    public init(
        id: String,
        provider: CloudProvider,
        name: String,
        icon: CloudFolderIcon,
        isCustom: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.icon = icon
        self.isCustom = isCustom
    }

    public static func builtIn(provider: CloudProvider, environment: CloudEnvironment) -> CloudFolder {
        CloudFolder(
            id: "\(provider.rawValue):\(environment.rawValue)",
            provider: provider,
            name: environment.rawValue,
            icon: environment.icon,
            isCustom: false
        )
    }
}

public struct ProfileGroup: Identifiable, Sendable {
    public var id: String { folder.id }
    public var folder: CloudFolder
    public var profiles: [CloudProfile]

    public init(folder: CloudFolder, profiles: [CloudProfile]) {
        self.folder = folder
        self.profiles = profiles
    }
}

public struct AWSProfileDraft: Equatable, Sendable {
    public var name = ""
    public var ssoStartURL = ""
    public var ssoRegion = ""
    public var accountID = ""
    public var roleName = ""
    public var defaultRegion = ""

    public init() {}

    public init(profile: CloudProfile, duplicate: Bool = false) {
        self.name = duplicate ? "\(profile.name)-copy" : profile.name
        self.ssoStartURL = profile.ssoStartURL
        self.ssoRegion = profile.ssoRegion
        self.accountID = profile.accountID
        self.roleName = profile.roleName
        self.defaultRegion = profile.region
    }
}

public struct GCPProfileDraft: Equatable, Sendable {
    public var name = ""
    public var project = ""
    public var account = ""
    public var region = ""

    public init() {}

    public init(profile: CloudProfile, duplicate: Bool = false) {
        self.name = duplicate ? "\(profile.name)-copy" : profile.name
        self.project = profile.accountID
        self.account = profile.roleName
        self.region = profile.region
    }
}

public struct AzureProfileDraft: Equatable, Sendable {
    public var name = ""
    public var subscriptionID = ""
    public var tenantID = ""
    public var location = ""

    public init() {}

    public init(profile: CloudProfile, duplicate: Bool = false) {
        self.name = duplicate ? "\(profile.name)-copy" : profile.name
        self.subscriptionID = profile.accountID
        self.tenantID = profile.roleName
        self.location = profile.region
    }
}

public enum SidebarSelection: Hashable, Codable, Sendable {
    case profile(String)
    case folder(String)
}
