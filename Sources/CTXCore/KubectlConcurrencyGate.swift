import Foundation

/// Which screen a fetch is for — decides whether it competes for a background
/// concurrency slot at all.
public enum FetchPriority: Sendable {
    /// The screen the user is actually looking at (screen open, Retry, namespace
    /// switch's current section). Always proceeds immediately — never queued
    /// behind prefetch, however many background fetches are already running.
    case active
    /// Workspace-open and namespace-switch prefetch of everything else. Capped
    /// to a small number of concurrent kubectl processes so a wave of eight
    /// prefetch calls can't flood the same auth plugin the active screen is also
    /// waiting on.
    case background
}

/// Caps concurrent *background* kubectl launches so prefetch can never compete
/// with — or slow down — the screen the user is actually looking at. Active
/// fetches never touch this gate at all; only `.background` ones acquire a slot
/// before their live kubectl call and release it right after.
public actor KubectlConcurrencyGate {
    private let maxConcurrentBackground: Int
    private var activeCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiterOrder: [UUID] = []

    public init(maxConcurrentBackground: Int = 3) {
        self.maxConcurrentBackground = maxConcurrentBackground
    }

    /// Waits for a slot. Throws `CancellationError` if the calling `Task` is
    /// cancelled while still queued — a plain `withCheckedContinuation` does
    /// *not* observe cancellation on its own, which would otherwise leave a
    /// cancelled waiter (e.g. one preempted by a higher-priority `.active`
    /// fetch for the same key) parked in the queue forever, never releasing
    /// the slot it's holding a place for.
    public func acquire() async throws {
        if activeCount < maxConcurrentBackground {
            activeCount += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                waiterOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        activeCount += 1
    }

    public func release() {
        activeCount -= 1
        guard !waiterOrder.isEmpty else { return }
        let id = waiterOrder.removeFirst()
        waiters.removeValue(forKey: id)?.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}
