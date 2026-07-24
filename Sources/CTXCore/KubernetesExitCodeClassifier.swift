import Foundation
import SwiftUI

public struct ExitCodeDiagnosis: Equatable, Sendable {
    public let code: Int
    public let title: String
    public let detail: String
    public let isCritical: Bool
    public let systemImage: String

    public var tint: Color {
        isCritical ? .red : .orange
    }
}

public enum KubernetesExitCodeClassifier {
    /// Classifies standard container exit codes into human-readable, diagnostic insights.
    public static func classify(code: Int, reason: String? = nil) -> ExitCodeDiagnosis {
        if let reason, reason.localizedCaseInsensitiveContains("OOMKilled") || code == 137 {
            return ExitCodeDiagnosis(
                code: 137,
                title: "OOMKilled (Exit 137)",
                detail: "Container exceeded its memory limit and was killed by Linux OOM-killer.",
                isCritical: true,
                systemImage: "memorychip"
            )
        }

        switch code {
        case 0:
            return ExitCodeDiagnosis(
                code: 0,
                title: "Completed (Exit 0)",
                detail: "Container exited cleanly with success status.",
                isCritical: false,
                systemImage: "checkmark.circle"
            )
        case 1:
            return ExitCodeDiagnosis(
                code: 1,
                title: "App Exception (Exit 1)",
                detail: "Application terminated due to an uncaught exception or error.",
                isCritical: true,
                systemImage: "exclamationmark.triangle"
            )
        case 126:
            return ExitCodeDiagnosis(
                code: 126,
                title: "Command Non-Executable (Exit 126)",
                detail: "Command specified in container spec could not be executed.",
                isCritical: true,
                systemImage: "xmark.octagon"
            )
        case 127:
            return ExitCodeDiagnosis(
                code: 127,
                title: "Command Not Found (Exit 127)",
                detail: "Binary or script specified in container command was not found.",
                isCritical: true,
                systemImage: "magnifyingglass.badge.xmark"
            )
        case 139:
            return ExitCodeDiagnosis(
                code: 139,
                title: "Segmentation Fault (Exit 139)",
                detail: "Container crashed due to illegal memory access (SIGSEGV).",
                isCritical: true,
                systemImage: "bolt.horizontal.circle"
            )
        case 143:
            return ExitCodeDiagnosis(
                code: 143,
                title: "SIGTERM Terminated (Exit 143)",
                detail: "Container received termination signal and stopped gracefully.",
                isCritical: false,
                systemImage: "arrow.right.circle"
            )
        default:
            return ExitCodeDiagnosis(
                code: code,
                title: "Terminated (Exit \(code))",
                detail: reason ?? "Container exited with non-zero status code \(code).",
                isCritical: code != 0,
                systemImage: "exclamationmark.circle"
            )
        }
    }
}
