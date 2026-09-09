import Foundation

extension ProfileStore {
    /// The local app user stays constant when cloud sessions change.
    public var localIdentityLabel: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }

    public var localIdentityInitials: String {
        let words = localIdentityLabel.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    public var activeIdentityLabel: String {
        if !activeGCPProfile.isEmpty,
           let gcp = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPProfile }),
           !gcp.roleName.isEmpty {
            return gcp.roleName
        }
        if !awsIdentity.isEmpty {
            return awsIdentity
        }
        if !activeAWSProfile.isEmpty,
           let aws = profiles.first(where: { $0.provider == .aws && $0.name == activeAWSProfile }) {
            return aws.accountID.isEmpty ? aws.name : "\(aws.name) · \(aws.accountID)"
        }
        let fullName = NSFullUserName()
        return fullName.isEmpty ? NSUserName() : fullName
    }

    public var activeIdentityInitials: String {
        let label = activeIdentityLabel
        let base = label.contains("@") ? String(label.split(separator: "@").first ?? "") : label
        let parts = base
            .split(whereSeparator: { $0 == "." || $0 == " " || $0 == "-" || $0 == "_" })
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(base.prefix(2)).uppercased()
    }

    public var hasActiveConnectedProfile: Bool {
        profiles.contains { profile in
            isActive(profile) && profile.status == .connected
        }
    }

    public var isCloudIdentityActive: Bool {
        if !activeAWSProfile.isEmpty,
           let aws = profiles.first(where: { $0.provider == .aws && $0.name == activeAWSProfile }),
           aws.status == .connected {
            return true
        }
        if !activeGCPProfile.isEmpty,
           let gcp = profiles.first(where: { $0.provider == .gcp && $0.name == activeGCPProfile }),
           gcp.status == .connected {
            return true
        }
        if !activeAzureProfile.isEmpty,
           let azure = profiles.first(where: { $0.provider == .azure && $0.name == activeAzureProfile }),
           azure.status == .connected {
            return true
        }
        if !activeKubeContext.isEmpty,
           let kube = profiles.first(where: { $0.provider == .kubernetes && $0.name == activeKubeContext }),
           kube.status == .connected {
            return true
        }
        return false
    }

    public var activeIdentityStatusLabel: String {
        var connectedLabels: [String] = []
        if activeProfile(for: .aws) != nil { connectedLabels.append("AWS") }
        if activeProfile(for: .gcp) != nil { connectedLabels.append("GCP") }
        if activeProfile(for: .azure) != nil { connectedLabels.append("Azure") }
        if activeProfile(for: .kubernetes) != nil { connectedLabels.append("K8s") }

        if !connectedLabels.isEmpty {
            return connectedLabels.joined(separator: " · ") + " Connected"
        }
        return "Local User"
    }
}
