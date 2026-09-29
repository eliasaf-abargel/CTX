import Foundation

public struct YAMLDiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added
        case removed
        case unchanged
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let originalLineNumber: Int?
    public let newLineNumber: Int?

    public init(id: Int, kind: Kind, text: String, originalLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.originalLineNumber = originalLineNumber
        self.newLineNumber = newLineNumber
    }
}

public struct YAMLDiffSummary: Equatable, Sendable {
    public let additions: Int
    public let deletions: Int
    public let unchanged: Int
    public let lines: [YAMLDiffLine]

    public var hasChanges: Bool {
        additions > 0 || deletions > 0
    }

    public static let empty = YAMLDiffSummary(additions: 0, deletions: 0, unchanged: 0, lines: [])
}

public enum YAMLDiffCalculator {
    public static func diff(original: String, modified: String) -> YAMLDiffSummary {
        let origLines = original.components(separatedBy: "\n")
        let modLines = modified.components(separatedBy: "\n")

        let n = origLines.count
        let m = modLines.count

        // Guard against massive files to maintain instant zero-lag UI
        if n > 2000 || m > 2000 {
            return fallbackLineDiff(origLines: origLines, modLines: modLines)
        }

        // Standard LCS table
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if origLines[i] == modLines[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // Backtrack
        var diffLines: [YAMLDiffLine] = []
        var i = n
        var j = m
        var nextId = n + m

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && origLines[i - 1] == modLines[j - 1] {
                diffLines.append(YAMLDiffLine(
                    id: nextId,
                    kind: .unchanged,
                    text: origLines[i - 1],
                    originalLineNumber: i,
                    newLineNumber: j
                ))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                diffLines.append(YAMLDiffLine(
                    id: nextId,
                    kind: .added,
                    text: modLines[j - 1],
                    originalLineNumber: nil,
                    newLineNumber: j
                ))
                j -= 1
            } else if i > 0 && (j == 0 || lcs[i][j - 1] < lcs[i - 1][j]) {
                diffLines.append(YAMLDiffLine(
                    id: nextId,
                    kind: .removed,
                    text: origLines[i - 1],
                    originalLineNumber: i,
                    newLineNumber: nil
                ))
                i -= 1
            }
            nextId -= 1
        }

        diffLines.reverse()

        var additions = 0
        var deletions = 0
        var unchanged = 0

        for line in diffLines {
            switch line.kind {
            case .added: additions += 1
            case .removed: deletions += 1
            case .unchanged: unchanged += 1
            }
        }

        return YAMLDiffSummary(
            additions: additions,
            deletions: deletions,
            unchanged: unchanged,
            lines: diffLines
        )
    }

    private static func fallbackLineDiff(origLines: [String], modLines: [String]) -> YAMLDiffSummary {
        var diffLines: [YAMLDiffLine] = []
        var additions = 0
        var deletions = 0
        var unchanged = 0

        let maxCount = max(origLines.count, modLines.count)
        for idx in 0..<maxCount {
            let o = idx < origLines.count ? origLines[idx] : nil
            let m = idx < modLines.count ? modLines[idx] : nil

            if let o = o, let m = m, o == m {
                diffLines.append(YAMLDiffLine(id: idx, kind: .unchanged, text: o, originalLineNumber: idx + 1, newLineNumber: idx + 1))
                unchanged += 1
            } else {
                if let o = o {
                    diffLines.append(YAMLDiffLine(id: idx * 2, kind: .removed, text: o, originalLineNumber: idx + 1, newLineNumber: nil))
                    deletions += 1
                }
                if let m = m {
                    diffLines.append(YAMLDiffLine(id: idx * 2 + 1, kind: .added, text: m, originalLineNumber: nil, newLineNumber: idx + 1))
                    additions += 1
                }
            }
        }

        return YAMLDiffSummary(additions: additions, deletions: deletions, unchanged: unchanged, lines: diffLines)
    }
}
