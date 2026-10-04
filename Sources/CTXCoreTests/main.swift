import Combine
import CTXCore
import Foundation

// Point diagnostics at a throwaway directory before anything can log. CTXPerfLog
// records on every timed step, so without this the suite writes into the real
// ~/.config/ctx/diagnostics and rolls the person's own history out of it.
setenv(
    "CTX_DIAGNOSTICS_DIR",
    NSTemporaryDirectory() + "ctx-tests-diagnostics-" + UUID().uuidString,
    1
)

runCloudProviderDetectionTests()
try await runConnectionRecoveryTests()
try runKubeIndentedDiscoveryTests()
try await runKubernetesDiscoveryAndConfigTests()
try await runKubernetesInspectionAndCacheTests()
try await runCloudProfileStoreTests()
try await runProfileLifecycleActivationTests()
try await runProfileLifecyclePresentationTests()
try await runProfileLifecycleAuthorityTests()
try await runProfileLifecycleKubernetesTests()
try await runCloudCommandSafetyTests()
try runKubernetesResourceInspectionTests()
try await runProfileGroupingAndFilteringTests()
try await runKubernetesClusterMetricsTests()
try runKubernetesTopologyTests()
try await runKubernetesGitOpsAndHelmTests()
runAWSSSOSessionConsolidationTests()
runConfigBackupTests()
runTerminalLauncherTests()
runAWSCredentialScopeTests()
runShellIntegrationTests()
runSessionScopeTests()
try runKubernetesDiagnosticRulesTests()
await runKubernetesWorkloadLifecycleTests()
try await runMCPServerAndSafetyTests()
runGitRepositoryURLHelperTests()
runKubernetesDiagnosticGuideTests()

print("CTXCoreTests passed")
