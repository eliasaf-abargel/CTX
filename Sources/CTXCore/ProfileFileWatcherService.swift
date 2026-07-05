import Foundation

public final class ProfileFileWatcherService {
    private var sources: [DispatchSourceFileSystemObject] = []

    public init() {}

    public func start(
        kubeConfigPath: String?,
        awsConfigPath: String,
        gcpActiveConfigPath: String,
        gcpConfigsDirPath: String,
        azureProfilesDirPath: String,
        onRefresh: @escaping () -> Void,
        onGCPActiveConfigChanged: @escaping () -> Void
    ) {
        stop()

        if let kubeConfigPath {
            watch(path: kubeConfigPath, handler: onRefresh)
        }
        watch(path: awsConfigPath, handler: onRefresh)
        watch(path: gcpActiveConfigPath, handler: onGCPActiveConfigChanged)
        watch(path: gcpConfigsDirPath, handler: onRefresh)

        let azureURL = URL(fileURLWithPath: azureProfilesDirPath)
        try? FileManager.default.createDirectory(at: azureURL, withIntermediateDirectories: true)
        watch(path: azureProfilesDirPath, handler: onRefresh)
    }

    public func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func watch(path: String, handler: @escaping () -> Void) {
        guard let source = makeWatcher(path: path, handler: handler) else { return }
        sources.append(source)
    }

    private func makeWatcher(path: String, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
