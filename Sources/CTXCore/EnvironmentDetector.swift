import Foundation

public enum EnvironmentDetector {
    public static func detect(contextName: String, clusterName: String) -> EnvironmentDetectionResult {
        let candidates = [
            ("context", contextName),
            ("cluster", clusterName)
        ]

        for (source, value) in candidates {
            let tokens = tokenize(value)
            if tokens.contains(where: { ["prod", "production", "prd"].contains($0) }) {
                return EnvironmentDetectionResult(type: .production, confidence: 0.9, source: source)
            }
            if tokens.contains(where: { ["stg", "stage", "staging"].contains($0) }) {
                return EnvironmentDetectionResult(type: .staging, confidence: 0.85, source: source)
            }
            if tokens.contains(where: { ["dev", "development"].contains($0) }) {
                return EnvironmentDetectionResult(type: .development, confidence: 0.85, source: source)
            }
            if tokens.contains(where: { ["admin", "root", "management", "mgmt"].contains($0) }) {
                return EnvironmentDetectionResult(type: .admin, confidence: 0.8, source: source)
            }
        }

        return EnvironmentDetectionResult(type: .unknown, confidence: 0, source: "none")
    }

    private static func tokenize(_ value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
