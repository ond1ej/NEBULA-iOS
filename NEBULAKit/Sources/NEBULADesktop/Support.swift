import Foundation
import Synchronization

/// Thrown by `withDeadline` when the operation did not finish in time.
struct DeadlineExceeded: Error, Sendable {}

/// A thread-safe "first caller wins" flag.
final class OnceFlag: Sendable {
    private let done = Mutex(false)

    /// True exactly once.
    func claim() -> Bool {
        done.withLock { d in
            if d { return false }
            d = true
            return true
        }
    }
}

/// A thread-safe holder for a task handle set after creation.
final class TaskHandleBox: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    func set(_ t: Task<Void, Never>) { task.withLock { $0 = t } }
    func cancel() { task.withLock { $0 }?.cancel() }
}

/// Runs `operation` but stops waiting after `timeout` (the operation is cancelled and a late result ignored).
/// Unlike a task group this never blocks on an operation that ignores cancellation, which matters for best-effort
/// clean-up calls (release / disconnect) over a dead network.
func withDeadline<T: Sendable>(_ timeout: Duration,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = OnceFlag()
    let workBox = TaskHandleBox()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            if once.claim() {
                workBox.cancel()
                continuation.resume(throwing: DeadlineExceeded())
            }
        }
        let work = Task {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            timer.cancel()
            if once.claim() { continuation.resume(with: result) }
        }
        workBox.set(work)
    }
}

extension Duration {
    /// Seconds as a floating-point value.
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
