import Foundation
import Synchronization

/// A bidirectional byte pipe carrying the raw RFB stream (in NEBULA: binary WebSocket frames through the host
/// proxy). Chunk boundaries carry no meaning; the client re-frames the stream itself.
public protocol RFBTransport: Sendable {
    /// Sends bytes (one or more complete RFB client messages).
    func send(_ data: Data) async throws
    /// Receives the next chunk of bytes; throws `RFBTransportError` when the pipe is closed or fails.
    func receive() async throws -> Data
    /// Closes both directions. Idempotent; pending and later `receive()` calls throw.
    func close()
}

/// Transport-level failures.
public enum RFBTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The connection was closed (WebSocket close code and reason when known).
    case closed(code: Int?, reason: String?)
    /// The server rejected the WebSocket upgrade (HTTP status), e.g. 403 for a used or expired live token.
    case rejected(status: Int)
    /// The connection could not be established or broke.
    case connectionFailed(String)
    /// Opening or a keep-alive ping timed out.
    case timedOut

    public var description: String {
        switch self {
        case .closed(let code, let reason):
            "connection closed" + (code.map { " (\($0))" } ?? "") + (reason.map { ": \($0)" } ?? "")
        case .rejected(let status): "connection rejected (HTTP \(status))"
        case .connectionFailed(let m): "connection failed: \(m)"
        case .timedOut: "connection timed out"
        }
    }

    /// True for close codes / statuses that mean "not allowed" (bad or reused live token, missing permission).
    public var isAuthorizationFailure: Bool {
        switch self {
        case .closed(let code?, _): code == 4401 || code == 4403
        case .rejected(let status): status == 401 || status == 403
        default: false
        }
    }
}

/// An in-memory transport pair for tests and previews: what one end sends, the other end receives.
public final class InMemoryRFBTransport: RFBTransport {
    final class Pipe: Sendable {
        private struct State {
            var queue: [Data] = []
            var head = 0
            var waiter: (id: UInt64, continuation: CheckedContinuation<Data, any Error>)?
            var nextID: UInt64 = 0
            var closed = false
        }

        private let state = Mutex(State())

        func push(_ data: Data) -> Bool {
            let waiter = state.withLock { s -> CheckedContinuation<Data, any Error>?? in
                guard !s.closed else { return .none }
                if let w = s.waiter {
                    s.waiter = nil
                    return .some(w.continuation)
                }
                s.queue.append(data)
                return .some(nil)
            }
            switch waiter {
            case .none: return false
            case .some(let c): c?.resume(returning: data); return true
            }
        }

        func pop() async throws -> Data {
            let id = state.withLock { s -> UInt64 in
                s.nextID &+= 1
                return s.nextID
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, any Error>) in
                    enum Next { case data(Data), closed, cancelled, wait }
                    let next = state.withLock { s -> Next in
                        if Task.isCancelled { return .cancelled }
                        if s.head < s.queue.count {
                            let d = s.queue[s.head]
                            s.head += 1
                            if s.head > 64, s.head * 2 > s.queue.count {
                                s.queue.removeFirst(s.head)
                                s.head = 0
                            }
                            return .data(d)
                        }
                        if s.closed { return .closed }
                        s.waiter = (id, c)
                        return .wait
                    }
                    switch next {
                    case .data(let d): c.resume(returning: d)
                    case .closed: c.resume(throwing: RFBTransportError.closed(code: nil, reason: nil))
                    case .cancelled: c.resume(throwing: CancellationError())
                    case .wait: break
                    }
                }
            } onCancel: {
                let c = state.withLock { s -> CheckedContinuation<Data, any Error>? in
                    guard let w = s.waiter, w.id == id else { return nil }
                    s.waiter = nil
                    return w.continuation
                }
                c?.resume(throwing: CancellationError())
            }
        }

        func close() {
            let waiter = state.withLock { s -> CheckedContinuation<Data, any Error>? in
                s.closed = true
                defer { s.waiter = nil }
                return s.waiter?.continuation
            }
            waiter?.resume(throwing: RFBTransportError.closed(code: nil, reason: nil))
        }

        var isClosed: Bool { state.withLock { $0.closed } }
    }

    private let inbound: Pipe
    private let outbound: Pipe

    private init(inbound: Pipe, outbound: Pipe) {
        self.inbound = inbound
        self.outbound = outbound
    }

    /// Two connected ends.
    public static func pair() -> (client: InMemoryRFBTransport, server: InMemoryRFBTransport) {
        let a = Pipe(), b = Pipe()
        return (InMemoryRFBTransport(inbound: a, outbound: b), InMemoryRFBTransport(inbound: b, outbound: a))
    }

    public func send(_ data: Data) async throws {
        guard outbound.push(data) else { throw RFBTransportError.closed(code: nil, reason: nil) }
    }

    public func receive() async throws -> Data {
        try await inbound.pop()
    }

    public func close() {
        inbound.close()
        outbound.close()
    }

    /// True once either end closed the pipe.
    public var isClosed: Bool { inbound.isClosed || outbound.isClosed }
}
