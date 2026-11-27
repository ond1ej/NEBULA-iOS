import Foundation
import Synchronization

/// RFB over a binary WebSocket (subprotocol "binary", as noVNC), the way NEBULA's host proxies the agent's Xvnc.
///
/// * Opens lazily on the first `send`/`receive`, with an open timeout.
/// * Pings every `pingInterval`; a missing pong fails the connection (half-open TCP over mobile networks).
/// * Close codes and rejected upgrades are mapped to `RFBTransportError` (4401/4403 and HTTP 403 mean the live token
///   was refused — the session then needs a new connect).
/// * Ephemeral URL session: no cookies or cache are persisted; the URL carries the single-use tokens.
public final class WebSocketRFBTransport: NSObject, RFBTransport, URLSessionWebSocketDelegate, Sendable {
    public struct Options: Sendable {
        /// Extra HTTP headers for the upgrade request (e.g. Origin, if the gateway requires one).
        public var headers: [String: String]
        public var pingInterval: Duration
        public var pongTimeout: Duration
        public var openTimeout: Duration
        public var maximumMessageSize: Int

        public init(headers: [String: String] = [:], pingInterval: Duration = .seconds(20),
                    pongTimeout: Duration = .seconds(10), openTimeout: Duration = .seconds(15),
                    maximumMessageSize: Int = 16 << 20) {
            self.headers = headers
            self.pingInterval = pingInterval
            self.pongTimeout = pongTimeout
            self.openTimeout = openTimeout
            self.maximumMessageSize = maximumMessageSize
        }
    }

    private enum Phase { case idle, opening, open, closed }

    private struct State {
        var phase = Phase.idle
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var openWaiters: [CheckedContinuation<URLSessionWebSocketTask, any Error>] = []
        var failure: RFBTransportError?
        var closeCode: Int?
        var closeReason: String?
        var timers: [Task<Void, Never>] = []
    }

    private let url: URL
    private let options: Options
    private let state = Mutex(State())

    public init(url: URL, options: Options = Options()) {
        self.url = url
        self.options = options
        super.init()
    }

    // MARK: RFBTransport

    public func send(_ data: Data) async throws {
        let task = try await openTask()
        do {
            try await task.send(.data(data))
        } catch {
            throw mapped(error)
        }
    }

    public func receive() async throws -> Data {
        let task = try await openTask()
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw mapped(error)
            }
            switch message {
            case .data(let d): return d
            case .string(let s): return Data(s.utf8)
            @unknown default: continue
            }
        }
    }

    public func close() {
        fail(with: .closed(code: 1000, reason: "closed by client"), code: .normalClosure)
    }

    // MARK: Opening

    private func openTask() async throws -> URLSessionWebSocketTask {
        enum Fast { case ready(URLSessionWebSocketTask), failed(RFBTransportError), start, wait }
        let fast = state.withLock { s -> Fast in
            switch s.phase {
            case .open: return s.task.map(Fast.ready) ?? .failed(.connectionFailed("no task"))
            case .closed: return .failed(s.failure ?? .closed(code: nil, reason: nil))
            case .idle:
                s.phase = .opening
                return .start
            case .opening: return .wait
            }
        }
        switch fast {
        case .ready(let t): return t
        case .failed(let e): throw e
        case .start: start()
        case .wait: break
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URLSessionWebSocketTask, any Error>) in
            enum Now { case ready(URLSessionWebSocketTask), failed(RFBTransportError), queued }
            let now = state.withLock { s -> Now in
                switch s.phase {
                case .open: return s.task.map(Now.ready) ?? .failed(.connectionFailed("no task"))
                case .closed: return .failed(s.failure ?? .closed(code: nil, reason: nil))
                case .idle, .opening:
                    s.openWaiters.append(c)
                    return .queued
                }
            }
            switch now {
            case .ready(let t): c.resume(returning: t)
            case .failed(let e): c.resume(throwing: e)
            case .queued: break
            }
        }
    }

    private func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300 // idle desktops are quiet; pings keep the socket alive
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "nebula.live.websocket"
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: url)
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        for (k, v) in options.headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = options.maximumMessageSize

        let proceed = state.withLock { s -> Bool in
            guard s.phase == .opening else { return false }
            s.session = session
            s.task = task
            return true
        }
        guard proceed else {
            session.invalidateAndCancel()
            return
        }
        let timeout = options.openTimeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.isOpening else { return }
            self.fail(with: .timedOut, code: .goingAway)
        }
        state.withLock { $0.timers.append(timer) }
        task.resume()
    }

    private var isOpening: Bool { state.withLock { $0.phase == .opening } }

    private func didOpen(_ task: URLSessionWebSocketTask) {
        let waiters = state.withLock { s -> [CheckedContinuation<URLSessionWebSocketTask, any Error>] in
            guard s.phase == .opening, s.task === task else { return [] }
            s.phase = .open
            defer { s.openWaiters.removeAll() }
            return s.openWaiters
        }
        waiters.forEach { $0.resume(returning: task) }
        startPinging(task)
    }

    private func startPinging(_ task: URLSessionWebSocketTask) {
        let interval = options.pingInterval, pongTimeout = options.pongTimeout
        let pinger = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.isOpen else { return }
                do {
                    try await withDeadline(pongTimeout) {
                        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                            task.sendPing { error in
                                if let error { c.resume(throwing: error) } else { c.resume() }
                            }
                        }
                    }
                } catch {
                    self.fail(with: .timedOut, code: .goingAway)
                    return
                }
            }
        }
        state.withLock { $0.timers.append(pinger) }
    }

    private var isOpen: Bool { state.withLock { $0.phase == .open } }

    // MARK: Failure / close

    private func fail(with error: RFBTransportError, code: URLSessionWebSocketTask.CloseCode) {
        let (task, session, waiters, timers) = state.withLock {
            s -> (URLSessionWebSocketTask?, URLSession?, [CheckedContinuation<URLSessionWebSocketTask, any Error>],
                  [Task<Void, Never>]) in
            let result = (s.task, s.session, s.openWaiters, s.timers)
            if s.phase != .closed {
                s.phase = .closed
                s.failure = s.failure ?? error
            }
            s.openWaiters.removeAll()
            s.timers.removeAll()
            s.task = nil
            s.session = nil
            return result
        }
        let reported = state.withLock { $0.failure } ?? error
        waiters.forEach { $0.resume(throwing: reported) }
        timers.forEach { $0.cancel() }
        task?.cancel(with: code, reason: nil)
        session?.invalidateAndCancel() // breaks the session → delegate retain cycle
    }

    private func mapped(_ error: any Error) -> RFBTransportError {
        if let e = error as? RFBTransportError { return e }
        let s = state.withLock { s in (s.failure, s.closeCode, s.closeReason) }
        if let failure = s.0 { return failure }
        if let code = s.1 { return .closed(code: code, reason: s.2) }
        if (error as? URLError)?.code == .timedOut { return .timedOut }
        return .connectionFailed(error.localizedDescription)
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        didOpen(webSocketTask)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0.prefix(256), encoding: .utf8) }
        state.withLock { s in
            s.closeCode = closeCode.rawValue
            s.closeReason = text
        }
        fail(with: .closed(code: closeCode.rawValue, reason: text), code: .normalClosure)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let failure: RFBTransportError
        if let status, status != 101, status >= 300 {
            failure = .rejected(status: status)
        } else if let code = state.withLock({ $0.closeCode }) {
            failure = .closed(code: code, reason: state.withLock { $0.closeReason })
        } else if let error {
            failure = (error as? URLError)?.code == .timedOut ? .timedOut : .connectionFailed(error.localizedDescription)
        } else {
            failure = .closed(code: nil, reason: nil)
        }
        fail(with: failure, code: .normalClosure)
    }
}
