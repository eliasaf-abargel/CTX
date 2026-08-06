import Foundation

public final class ProfileFileWatcherService {
    /// One entry per registered watch. Keyed by a token rather than by path so two
    /// registrations for the same path — which happens when a user points more than
    /// one of the configured paths at the same file — both stay live instead of one
    /// silently cancelling the other along with its (different) handler.
    private struct Watch {
        let path: String
        let handler: () -> Void
        var source: DispatchSourceFileSystemObject
    }

    private let lock = NSLock()
    private var watches: [UUID: Watch] = [:]
    private var isStopped = false

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
        lock.lock()
        isStopped = false
        lock.unlock()

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
        lock.lock()
        isStopped = true
        let existing = watches
        watches.removeAll()
        lock.unlock()
        existing.values.forEach { $0.source.cancel() }
    }

    /// Watches `path` and keeps watching it across atomic replacements.
    ///
    /// `open(_:O_EVTONLY)` pins an inode, not a path. Every CLI CTX follows
    /// (`aws`, `gcloud`, `az`, `kubectl config`) writes by creating a temp file and
    /// renaming it over the target, which unlinks the inode the watcher holds — so a
    /// watcher armed once fires a single `.rename`/`.delete` and is then permanently
    /// deaf to the *file at that path*, which is what CTX actually wants to follow.
    /// On those two events the source is torn down and re-armed on the path.
    private func watch(path: String, handler: @escaping () -> Void) {
        arm(token: UUID(), path: path, handler: handler)
    }

    private func arm(token: UUID, path: String, handler: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let replaced = source.data.contains(.rename) || source.data.contains(.delete)
            handler()
            guard replaced, let self else { return }
            // Re-arm slightly later: the replacement file may not be in place at the
            // instant the rename event lands, and a failed re-open would silently
            // end the watch for good.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                self.rearm(token: token, previous: source)
            }
        }
        source.setCancelHandler { close(fd) }

        lock.lock()
        if isStopped {
            lock.unlock()
            source.cancel()
            return
        }
        watches[token] = Watch(path: path, handler: handler, source: source)
        lock.unlock()
        source.resume()
    }

    private func rearm(token: UUID, previous: DispatchSourceFileSystemObject) {
        lock.lock()
        // A `start()` or `stop()` already replaced this watch — don't resurrect it.
        guard !isStopped, let watch = watches[token], watch.source === previous else {
            lock.unlock()
            return
        }
        watches.removeValue(forKey: token)
        lock.unlock()
        previous.cancel()
        arm(token: token, path: watch.path, handler: watch.handler)
    }
}
