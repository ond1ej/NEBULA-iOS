import Foundation
import Network

/// Network reachability (NWPathMonitor) as an async stream of "online?" changes.
public final class Connectivity: Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "nebula.connectivity")

    public init() {}

    public func updates() -> AsyncStream<Bool> {
        AsyncStream { c in
            monitor.pathUpdateHandler = { path in c.yield(path.status == .satisfied) }
            c.onTermination = { [monitor] _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
