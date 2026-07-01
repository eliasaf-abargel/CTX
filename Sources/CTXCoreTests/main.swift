import CTXCore
import Foundation

func testProviderLabelsStayCloudSpecific() {
    assert(CloudProfile(provider: .aws, name: "prod").accountLabel == "AWS Account")
    assert(CloudProfile(provider: .gcp, name: "prod").roleLabel == "GCP Account")
    assert(CloudProfile(provider: .azure, name: "prod").regionLabel == "Default Location")
    assert(CloudProfile(provider: .kubernetes, name: "prod").typeDescription == "Kubernetes Context")
}

func testEnvironmentInferencePrefersSpecificProfileSignals() {
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "prod-admin")) == .production)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "stage-sso")) == .staging)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "dev-sandbox")) == .development)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "redshift-prod")) == .data)
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "it-admin")) == .admin)
}

func testBuiltInFolderIdentityIsStable() {
    let folder = CloudFolder.builtIn(provider: .aws, environment: .production)

    assert(folder.id == "AWS:Production")
    assert(folder.provider == .aws)
    assert(folder.name == "Production")
    assert(folder.icon == .server)
    assert(folder.isCustom == false)
}

func testAWSDraftDuplicatePreservesConfigurationAndRenamesCopy() {
    let profile = CloudProfile(
        provider: .aws,
        name: "prod-admin",
        accountID: "123456789012",
        roleName: "AdministratorAccess",
        region: "us-east-1",
        ssoStartURL: "https://example.awsapps.com/start",
        ssoRegion: "us-east-1"
    )

    let draft = AWSProfileDraft(profile: profile, duplicate: true)

    assert(draft.name == "prod-admin-copy")
    assert(draft.accountID == "123456789012")
    assert(draft.roleName == "AdministratorAccess")
    assert(draft.defaultRegion == "us-east-1")
    assert(draft.ssoStartURL == "https://example.awsapps.com/start")
    assert(draft.ssoRegion == "us-east-1")
}

testProviderLabelsStayCloudSpecific()
testEnvironmentInferencePrefersSpecificProfileSignals()
testBuiltInFolderIdentityIsStable()
testAWSDraftDuplicatePreservesConfigurationAndRenamesCopy()

print("CTXCoreTests passed")
