import Foundation
@testable import NEBULADesktop
import Network
import Synchronization
import Testing

/// The server end of a real WebSocket (Network.framework) as an `RFBTransport`, so the fake RFB server can run
/// behind an actual WebSocket stack.
final class NWServerTransport: RFBTransport, @unchecked Sendable {
    // NWConnection is thread-safe; callbacks run on `queue`.
    let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "rfb", metadata: [metadata])
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                                if let error { c.resume(throwing: error) } else { c.resume() }
                            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, any Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error { return c.resume(throwing: error) }
                guard let data else { return c.resume(throwing: RFBTransportError.closed(code: nil, reason: nil)) }
                c.resume(returning: data)
            }
        }
    }

    func close() { connection.cancel() }

    /// Sends a WebSocket close frame with `code`.
    func close(code: UInt16) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

/// A WebSocket server on 127.0.0.1 that accepts the "binary" subprotocol and hands out server transports.
final class LocalWebSocketServer: @unchecked Sendable {
    // Mutable state is guarded by `state`; the listener calls back on `queue`.
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nebula.tests.websocket")
    private struct State {
        var requestedProtocols: [[String]] = []
        var connections: [NWServerTransport] = []
        var waiters: [CheckedContinuation<NWServerTransport, Never>] = []
    }
    private final class Shared: Sendable {
        let state = Mutex(State())
    }
    private let shared = Shared()

    init(acceptSubprotocol: Bool = true) throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let shared = self.shared
        // Options must be complete before the listener copies its parameters.
        ws.setClientRequestHandler(queue) { protocols, _ in
            shared.state.withLock { $0.requestedProtocols.append(protocols) }
            let chosen = acceptSubprotocol && protocols.contains("binary") ? "binary" : nil
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: chosen)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            let transport = NWServerTransport(connection: connection, queue: queue)
            connection.start(queue: queue)
            let waiter = shared.state.withLock { s -> CheckedContinuation<NWServerTransport, Never>? in
                if s.waiters.isEmpty {
                    s.connections.append(transport)
                    return nil
                }
                return s.waiters.removeFirst()
            }
            waiter?.resume(returning: transport)
        }
    }

    func start() async throws -> UInt16 {
        final class Once: Sendable {
            let continuation = Mutex<CheckedContinuation<Void, any Error>?>(nil)
            func take() -> CheckedContinuation<Void, any Error>? { continuation.withLock { $0.take() } }
        }
        let ready = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            ready.continuation.withLock { $0 = c }
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready: ready.take()?.resume()
                case .failed(let e): ready.take()?.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return listener.port?.rawValue ?? 0
    }

    func nextConnection() async -> NWServerTransport {
        await withCheckedContinuation { (c: CheckedContinuation<NWServerTransport, Never>) in
            let ready = shared.state.withLock { s -> NWServerTransport? in
                if !s.connections.isEmpty { return s.connections.removeFirst() }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    var requestedProtocols: [[String]] { shared.state.withLock { $0.requestedProtocols } }

    func stop() { listener.cancel() }
}

@Suite("WebSocket transport (real WebSocket stack)", .serialized)
struct WebSocketTransportTests {
    @Test("Binary frames both ways with the \"binary\" subprotocol")
    func roundTrip() async throws {
        let server = try LocalWebSocketServer()
        let port = try await server.start()
        let client = WebSocketRFBTransport(url: URL(string: "ws://127.0.0.1:\(port)/api/v1/live/ws/s1?token=t")!)
        try await client.send(Data([1, 2, 3]))
        let serverEnd = await server.nextConnection()
        #expect(try await serverEnd.receive() == Data([1, 2, 3]))
        #expect(server.requestedProtocols.first == ["binary"], "requested: \(server.requestedProtocols)")
        let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await serverEnd.send(big)
        try await serverEnd.send(Data([9]))
        var received = Data()
        while received.count < big.count + 1 { received += try await client.receive() }
        #expect(received == big + Data([9]))
        client.close()
        await #expect(throws: RFBTransportError.self) { try await client.receive() }
        server.stop()
    }

    @Test("A full RFB session over a real WebSocket: handshake, setup, Tight update, input")
    func rfbOverWebSocket() async throws {
        let server = try LocalWebSocketServer()
        let port = try await server.start()
        let transport = WebSocketRFBTransport(url: URL(string: "ws://127.0.0.1:\(port)/live")!)
        let client = RFBClient(transport: transport)
        let run = Task { try await client.run() }
        let fake = FakeRFBServer(transport: await server.nextConnection())
        try await fake.handshake(width: 320, height: 200)
        await fake.startCollecting()
        #expect(await eventually { await fake.updateRequests.count == 1 })
        try await fake.sendUpdate([Wire.tightFill(0, 0, 320, 200, 0x0A0B0C),
                                   Wire.tightBasic(0, 0, 8, 8, stream: 0, filter: nil,
                                                   data: (0..<64).flatMap { _ in Wire.rgb(0xFF8000) },
                                                   deflater: Deflater())])
        #expect(await eventually { client.metrics.framebufferUpdates == 1 })
        #expect(await client.pixel(x: 4, y: 4) == 0xFFFF_8000)
        #expect(await client.pixel(x: 300, y: 100) == 0xFF0A_0B0C)
        #expect(await eventually { await fake.updateRequests.count == 2 })
        client.input.setEnabled(true)
        client.input.key(0x61, down: true)
        client.input.key(0x61, down: false)
        #expect(await eventually { await fake.inputMessages.count == 2 })
        client.close()
        await #expect(throws: (any Error).self) { try await run.value }
        server.stop()
    }

    @Test("A server close code is reported as a closed / failed connection")
    func serverClose() async throws {
        let server = try LocalWebSocketServer()
        let port = try await server.start()
        let client = WebSocketRFBTransport(url: URL(string: "ws://127.0.0.1:\(port)/live")!)
        try await client.send(Data([0]))
        let serverEnd = await server.nextConnection()
        _ = try await serverEnd.receive()
        serverEnd.close(code: 4403)
        do {
            while true { _ = try await client.receive() }
        } catch let error as RFBTransportError {
            switch error {
            case .closed, .connectionFailed: break
            default: Issue.record("unexpected \(error)")
            }
        }
        server.stop()
    }

    @Test("Nothing listening: the open fails quickly with a transport error")
    func refused() async throws {
        let server = try LocalWebSocketServer()
        let port = try await server.start()
        server.stop()
        try? await Task.sleep(for: .milliseconds(50))
        let client = WebSocketRFBTransport(url: URL(string: "ws://127.0.0.1:\(port)/live")!,
                                           options: .init(openTimeout: .seconds(3)))
        await #expect(throws: RFBTransportError.self) { try await client.receive() }
    }
}
