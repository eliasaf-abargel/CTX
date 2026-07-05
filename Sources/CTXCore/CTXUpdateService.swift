import Foundation

public enum CTXUpdateServiceError: LocalizedError, Equatable, Sendable {
    case invalidReleaseInfo
    case invalidDownloadURL
    case downloadFailed
    case extractFailed

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseInfo: "Failed to parse release information."
        case .invalidDownloadURL: "Invalid update download URL."
        case .downloadFailed: "Failed to download update file."
        case .extractFailed: "Failed to extract update package."
        }
    }
}

public struct CTXUpdateCheckResult: Sendable {
    public var tagName: String
    public var currentVersion: String
    public var isUpdateAvailable: Bool

    public init(tagName: String, currentVersion: String, isUpdateAvailable: Bool) {
        self.tagName = tagName
        self.currentVersion = currentVersion
        self.isUpdateAvailable = isUpdateAvailable
    }
}

public final class CTXUpdateService: Sendable {
    private let runner: any CloudCommandRunning
    private let currentVersion: @Sendable () -> String

    public init(
        runner: any CloudCommandRunning = CloudCommandRunner(),
        currentVersion: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        }
    ) {
        self.runner = runner
        self.currentVersion = currentVersion
    }

    public func checkForUpdates() async throws -> CTXUpdateCheckResult {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10.0

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let tagName = Self.releaseTag(from: data) else {
            throw CTXUpdateServiceError.invalidReleaseInfo
        }

        let current = currentVersion()
        return CTXUpdateCheckResult(
            tagName: tagName,
            currentVersion: current,
            isUpdateAvailable: Self.isUpdateAvailable(latestTag: tagName, currentVersion: current)
        )
    }

    public func install(tagName: String, targetBundlePath: String) async throws {
        guard let url = Self.downloadURL(for: tagName) else {
            throw CTXUpdateServiceError.invalidDownloadURL
        }

        let (tempZipURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CTXUpdateServiceError.downloadFailed
        }

        let tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)

        let unzipResult = await runner.run([
            "unzip", "-q", "-o", tempZipURL.path,
            "-d", tempDirURL.path
        ])
        guard unzipResult.exitCode == 0 else {
            throw CTXUpdateServiceError.extractFailed
        }

        try launchInstaller(sourcePath: tempDirURL.appendingPathComponent("CTX.app").path, targetPath: targetBundlePath, in: tempDirURL)
    }

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/eliasaf-abargel/CTX/releases/latest")!

    public static func downloadURL(for tagName: String) -> URL? {
        URL(string: "https://github.com/eliasaf-abargel/CTX/releases/download/\(tagName)/CTX.app.zip")
    }

    public static func releaseTag(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String
        else {
            return nil
        }
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isUpdateAvailable(latestTag: String, currentVersion: String) -> Bool {
        let latestVersion = latestTag.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
        return latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    private func launchInstaller(sourcePath: String, targetPath: String, in tempDirURL: URL) throws {
        let scriptURL = tempDirURL.appendingPathComponent("install.sh")
        let script = """
        #!/bin/sh
        sleep 0.5
        rm -rf \(Self.shellQuoted(targetPath))
        mv \(Self.shellQuoted(sourcePath)) \(Self.shellQuoted(targetPath))
        xattr -rd com.apple.quarantine \(Self.shellQuoted(targetPath)) >/dev/null 2>&1 || true
        open \(Self.shellQuoted(targetPath))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
