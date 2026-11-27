import Foundation
import NEBULACore

/// Incremental text/event-stream parser (WHATWG server-sent events): feed it lines, get events.
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public var id: String?
        public var event: String
        public var data: String
    }

    private var data: [String] = []
    private var event = ""
    private var id: String?
    public private(set) var retryMs: Int?

    public init() {}

    /// One line without its terminator. Returns an event when a blank line completes one.
    public mutating func feed(line: String) -> Event? {
        if line.isEmpty {
            defer { data = []; event = ""; id = nil }
            guard !data.isEmpty else { return nil }
            return Event(id: id, event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }  // comment / keepalive
        let field: Substring
        var value: Substring
        if let i = line.firstIndex(of: ":") {
            field = line[..<i]
            value = line[line.index(after: i)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": data.append(String(value))
        case "event": event = String(value)
        case "id": if !value.contains("\0") { id = String(value) }
        case "retry": if let n = Int(value) { retryMs = n }
        default: break
        }
        return nil
    }
}

/// The live event stream (GET /api/v1/events) with resume from the last sequence, automatic reconnection with
/// jittered backoff, and an explicit stop when the app goes to the background (iOS does not keep sockets alive).
public actor EventStream {
    public enum Status: Sendable, Equatable { case idle, connecting, live, waiting(retryIn: Double), stopped }

    private let client: APIClient
    private var lastSequence: Int?
    private var task: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    private(set) public var status: Status = .idle
    private var failures = 0

    public init(client: APIClient, since: Int? = nil) {
        self.client = client
        self.lastSequence = since
    }

    public var resumeSequence: Int? { lastSequence }

    /// Events from now on (each subscriber gets its own stream).
    public func events() -> AsyncStream<ServerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(500)) { c in
            continuations[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }

    public func statusUpdates() -> AsyncStream<Status> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(5)) { c in
            statusContinuations[id] = c
            c.yield(status)
            c.onTermination = { [weak self] _ in Task { await self?.removeStatus(id) } }
        }
    }

    private func remove(_ id: UUID) { continuations[id] = nil }
    private func removeStatus(_ id: UUID) { statusContinuations[id] = nil }

    private func set(_ s: Status) {
        status = s
        for c in statusContinuations.values { c.yield(s) }
    }

    public func start() {
        guard task == nil else { return }
        failures = 0
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        set(.stopped)
    }

    /// Reconnect right away (e.g. the network came back) instead of waiting for the backoff.
    public func reconnectNow() {
        stop()
        start()
    }

    private func run() async {
        while !Task.isCancelled {
            set(.connecting)
            do {
                try await connectOnce()
                failures = 0
            } catch is CancellationError {
                break
            } catch {
                failures += 1
            }
            if Task.isCancelled { break }
            let base = min(30.0, pow(2.0, Double(min(failures, 5))) * 0.5)
            let wait = base * Double.random(in: 0.7...1.3)
            set(.waiting(retryIn: wait))
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func connectOnce() async throws {
        let query: [String: String?] = ["since": lastSequence.map(String.init)]
        guard let tokens = client.tokens else { throw APIError(status: 401, code: "unauthenticated", message: "") }
        var token = try await tokens.sessionToken(forceRefresh: false)
        for attempt in 0..<2 {
            var req = URLRequest(url: client.url("/events", query: query))
            req.timeoutInterval = 60  // keepalives arrive every 15 s
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (bytes, resp) = try await client.session.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                token = try await tokens.sessionToken(forceRefresh: true)
                continue
            }
            guard status == 200 else { throw APIError(status: status, code: "http_\(status)", message: "") }
            set(.live)
            var parser = SSEParser()
            let decoder = NJSON.decoder()
            // NOTE: `bytes.lines` drops empty lines, but a blank line is what ends an SSE event — split by hand.
            var line: [UInt8] = []
            line.reserveCapacity(4096)
            for try await byte in bytes {
                if byte != 0x0A {
                    if line.count < 1_048_576 { line.append(byte) }
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if Task.isCancelled { throw CancellationError() }
                guard let ev = parser.feed(line: text) else { continue }
                guard let raw = ev.data.data(using: .utf8),
                      let event = try? decoder.decode(ServerEvent.self, from: raw) else { continue }
                if let seq = event.sequence {
                    if let last = lastSequence, seq <= last { continue }  // never deliver twice after a reconnect
                    lastSequence = seq
                }
                for c in continuations.values { c.yield(event) }
            }
            return  // orderly server close
        }
    }
}
