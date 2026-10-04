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
    assert(CloudEnvironment.infer(from: CloudProfile(provider: .aws, name: "ops-admin")) == .admin)
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

func testKubernetesContextProfileMapsToCloudProfile() {
    let detection = EnvironmentDetectionResult(type: .production, confidence: 0.9, source: "context")
    let profile = KubernetesContextProfile(
        contextName: "eks-prod",
        clusterName: "prod-cluster",
        userName: "prod-user",
        namespace: "default",
        kubeconfigPath: "/tmp/kubeconfig",
        providerType: .eks,
        environmentDetection: detection,
        isCurrent: true,
        clusterMetadata: ClusterMetadata(id: "prod-cluster", name: "prod-cluster", serverURL: "https://example.eks.amazonaws.com")
    )

    assert(profile.id == "/tmp/kubeconfig:eks-prod")
    assert(profile.environmentType == .production)
    assert(profile.providerType == .eks)
    let cloudProfile = KubernetesProfileAdapter.cloudProfile(from: profile)
    assert(cloudProfile.provider == .kubernetes)
    assert(cloudProfile.name == "eks-prod")
    assert(cloudProfile.accountID == "prod-cluster")
    assert(cloudProfile.roleName == "prod-user")
    assert(cloudProfile.region == "default")
}

func testEnvironmentDetection() {
    assert(EnvironmentDetector.detect(contextName: "shop-prod", clusterName: "").type == .production)
    assert(EnvironmentDetector.detect(contextName: "shop-staging", clusterName: "").type == .staging)
    assert(EnvironmentDetector.detect(contextName: "dev-west", clusterName: "").type == .development)
    assert(EnvironmentDetector.detect(contextName: "ops", clusterName: "root-management").type == .admin)
    assert(EnvironmentDetector.detect(contextName: "shared", clusterName: "shared").type == .unknown)
}

func testKubernetesProviderDetection() {
    assert(KubernetesProviderDetector.detect(contextName: "prod", clusterName: "eks-prod", serverURL: "") == .eks)
    assert(KubernetesProviderDetector.detect(contextName: "gke_project_zone_cluster", clusterName: "cluster", serverURL: "") == .gke)
    assert(KubernetesProviderDetector.detect(contextName: "aks-prod", clusterName: "prod", serverURL: "") == .aks)
    assert(KubernetesProviderDetector.detect(contextName: "kind-local", clusterName: "kind-local", serverURL: "https://127.0.0.1:6443") == .local)
    assert(KubernetesProviderDetector.detect(contextName: "shared", clusterName: "shared", serverURL: "https://10.0.0.1") == .unknown)
}



func runCloudProviderDetectionTests() {
    testProviderLabelsStayCloudSpecific()
    testEnvironmentInferencePrefersSpecificProfileSignals()
    testBuiltInFolderIdentityIsStable()
    testAWSDraftDuplicatePreservesConfigurationAndRenamesCopy()
    testKubernetesContextProfileMapsToCloudProfile()
    testEnvironmentDetection()
    testKubernetesProviderDetection()
}
