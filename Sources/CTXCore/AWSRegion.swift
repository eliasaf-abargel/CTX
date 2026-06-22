import Foundation

public struct AWSRegion: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    
    public var displayName: String {
        "\(id) (\(name))"
    }
    
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
    
    public static let allCases: [AWSRegion] = [
        // US
        AWSRegion(id: "us-east-1", name: "N. Virginia"),
        AWSRegion(id: "us-east-2", name: "Ohio"),
        AWSRegion(id: "us-west-1", name: "N. California"),
        AWSRegion(id: "us-west-2", name: "Oregon"),
        
        // Europe
        AWSRegion(id: "eu-west-1", name: "Ireland"),
        AWSRegion(id: "eu-west-2", name: "London"),
        AWSRegion(id: "eu-west-3", name: "Paris"),
        AWSRegion(id: "eu-central-1", name: "Frankfurt"),
        AWSRegion(id: "eu-central-2", name: "Zurich"),
        AWSRegion(id: "eu-north-1", name: "Stockholm"),
        AWSRegion(id: "eu-south-1", name: "Milan"),
        AWSRegion(id: "eu-south-2", name: "Spain"),
        
        // Asia Pacific
        AWSRegion(id: "ap-northeast-1", name: "Tokyo"),
        AWSRegion(id: "ap-northeast-2", name: "Seoul"),
        AWSRegion(id: "ap-northeast-3", name: "Osaka"),
        AWSRegion(id: "ap-south-1", name: "Mumbai"),
        AWSRegion(id: "ap-south-2", name: "Hyderabad"),
        AWSRegion(id: "ap-southeast-1", name: "Singapore"),
        AWSRegion(id: "ap-southeast-2", name: "Sydney"),
        AWSRegion(id: "ap-southeast-3", name: "Jakarta"),
        AWSRegion(id: "ap-southeast-4", name: "Melbourne"),
        AWSRegion(id: "ap-east-1", name: "Hong Kong"),
        
        // Canada
        AWSRegion(id: "ca-central-1", name: "Central"),
        AWSRegion(id: "ca-west-1", name: "Calgary"),
        
        // South America
        AWSRegion(id: "sa-east-1", name: "São Paulo"),
        
        // Middle East & Africa
        AWSRegion(id: "me-central-1", name: "UAE"),
        AWSRegion(id: "me-south-1", name: "Bahrain"),
        AWSRegion(id: "af-south-1", name: "Cape Town"),
        AWSRegion(id: "il-central-1", name: "Tel Aviv"),
        
        // GovCloud
        AWSRegion(id: "us-gov-east-1", name: "GovCloud East"),
        AWSRegion(id: "us-gov-west-1", name: "GovCloud West")
    ]
}

public enum AWSRegionGroup: String, CaseIterable, Identifiable, Sendable {
    case americas = "Americas"
    case europe = "Europe"
    case asiaPacific = "Asia Pacific & Israel"
    case middleEastAfrica = "Middle East & Africa"
    case govCloud = "GovCloud"
    
    public var id: String { rawValue }
    
    public var regions: [AWSRegion] {
        switch self {
        case .americas:
            AWSRegion.allCases.filter { ($0.id.hasPrefix("us-") && !$0.id.contains("gov")) || $0.id.hasPrefix("ca-") || $0.id.hasPrefix("sa-") }
        case .europe:
            AWSRegion.allCases.filter { $0.id.hasPrefix("eu-") }
        case .asiaPacific:
            AWSRegion.allCases.filter { $0.id.hasPrefix("ap-") || $0.id.hasPrefix("il-") }
        case .middleEastAfrica:
            AWSRegion.allCases.filter { $0.id.hasPrefix("me-") || $0.id.hasPrefix("af-") }
        case .govCloud:
            AWSRegion.allCases.filter { $0.id.contains("gov") }
        }
    }
}

