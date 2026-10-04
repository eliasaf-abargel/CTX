import CTXCore
import Foundation

func runKubernetesDiagnosticGuideTests() {
    let probesGuide = KubernetesDiagnosticGuide.guide(for: "RELIABILITY_MISSING_PROBES")
    assert(probesGuide.specPath.contains("livenessProbe"), "Must target livenessProbe")
    assert(probesGuide.suggestedYAML?.contains("livenessProbe") == true, "Must include suggested probes YAML")

    let limitsGuide = KubernetesDiagnosticGuide.guide(for: "RELIABILITY_NO_LIMITS")
    assert(limitsGuide.specPath.contains("resources"), "Must target resources")
    assert(limitsGuide.suggestedYAML?.contains("limits") == true, "Must include limits snippet")

    let privGuide = KubernetesDiagnosticGuide.guide(for: "SECURITY_PRIVILEGED")
    assert(privGuide.specPath.contains("privileged"), "Must target privileged")
}
