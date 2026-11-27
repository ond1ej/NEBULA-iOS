import CoreGraphics
import CZlib
import Foundation
import ImageIO
@testable import NEBULADesktop
import Synchronization

// MARK: - Waiting

/// Polls an async condition (actors) until it holds or the timeout passes.
func eventually(_ timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Polls a main-actor condition (the session) until it holds or the timeout passes.
@MainActor
func eventuallyMain(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - zlib (server side)

/// A persistent deflate stream, flushed with Z_SYNC_FLUSH per rectangle like TigerVNC.
final class Deflater {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    init(level: Int32 = 6) {
        stream.initialize(to: z_stream())
        let status = deflateInit_(stream, level, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK)
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func compress(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var output = [UInt8](repeating: 0, count: Int(deflateBound(stream, uLong(input.count))) + 64)
        let produced = input.withUnsafeMutableBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out -> Int in
                stream.pointee.next_in = inp.baseAddress
                stream.pointee.avail_in = uInt(inp.count)
                stream.pointee.next_out = out.baseAddress
                stream.pointee.avail_out = uInt(out.count)
                let status = deflate(stream, Z_SYNC_FLUSH)
                precondition(status == Z_OK)
                precondition(stream.pointee.avail_in == 0)
                return out.count - Int(stream.pointee.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }
}

// MARK: - Rectangle builders (server → client wire format)

/// Big-endian UInt32 at `i`, built in typed steps: one long `<<`/`|` chain times out Xcode 26's type checker.
func bigEndian32(_ b: [UInt8], at i: Int) -> UInt32 {
    var v = UInt32(b[i]) << 24
    v |= UInt32(b[i + 1]) << 16
    v |= UInt32(b[i + 2]) << 8
    v |= UInt32(b[i + 3])
    return v
}

enum Wire {
    static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func s32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }

    static func header(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int32) -> [UInt8] {
        u16(x) + u16(y) + u16(w) + u16(h) + s32(encoding)
    }

    static func update(_ rects: [[UInt8]], count: Int? = nil) -> [UInt8] {
        [0, 0] + u16(count ?? rects.count) + rects.flatMap { $0 }
    }

    /// Tight compact length.
    static func compact(_ n: Int) -> [UInt8] {
        var out = [UInt8(n & 0x7F)]
        if n > 0x7F {
            out[0] |= 0x80
            out.append(UInt8((n >> 7) & 0x7F))
            if n > 0x3FFF {
                out[1] |= 0x80
                out.append(UInt8((n >> 14) & 0xFF))
            }
        }
        return out
    }

    /// Raw rectangle; `colors` are 0xRRGGBB, row-major.
    static func raw(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ colors: [UInt32]) -> [UInt8] {
        header(x, y, w, h, 0) + colors.flatMap { c in
            [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), 0] // B G R X
        }
    }

    static func copyRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, from sx: Int, _ sy: Int) -> [UInt8] {
        header(x, y, w, h, 1) + u16(sx) + u16(sy)
    }

    static func tightFill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32, reset: UInt8 = 0) -> [UInt8] {
        header(x, y, w, h, 7) + [0x80 | reset] + rgb(color)
    }

    static func tightJPEG(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ jpeg: [UInt8]) -> [UInt8] {
        header(x, y, w, h, 7) + [0x90] + compact(jpeg.count) + jpeg
    }

    /// Tight basic compression. `filter` nil = implicit copy filter.
    static func tightBasic(_ x: Int, _ y: Int, _ w: Int, _ h: Int, stream: Int, filter: UInt8?,
                           filterParameters: [UInt8] = [], data: [UInt8], deflater: Deflater?,
                           reset: UInt8 = 0) -> [UInt8] {
        var control = UInt8(stream & 3) << 4 | reset
        if filter != nil { control |= 0x40 }
        var out = header(x, y, w, h, 7) + [control]
        if let filter { out += [filter] + filterParameters }
        if data.count < 12 {
            out += data
        } else {
            let z = deflater!.compress(data)
            out += compact(z.count) + z
        }
        return out
    }

    static func zrle(_ x: Int, _ y: Int, _ w: Int, _ h: Int, tiles: [UInt8], deflater: Deflater) -> [UInt8] {
        let z = deflater.compress(tiles)
        return header(x, y, w, h, 16) + u32(UInt32(z.count)) + z
    }

    static func rgb(_ c: UInt32) -> [UInt8] { [UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)] }
    static func cpixel(_ c: UInt32) -> [UInt8] { [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF)] }

    /// The Tight gradient filter's forward transform (test side).
    static func gradientEncode(_ colors: [UInt32], width w: Int, height h: Int) -> [UInt8] {
        let rgbBytes = colors.flatMap(rgb)
        func v(_ x: Int, _ y: Int, _ c: Int) -> Int { x < 0 || y < 0 ? 0 : Int(rgbBytes[(y * w + x) * 3 + c]) }
        var out: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let estimate = min(max(v(x, y - 1, c) + v(x - 1, y, c) - v(x - 1, y - 1, c), 0), 255)
                    out.append(UInt8(truncatingIfNeeded: v(x, y, c) - estimate))
                }
            }
        }
        return out
    }
}

/// A JPEG whose top half is `top` and bottom half `bottom` (0xRRGGBB), made with ImageIO.
func makeJPEG(width: Int, height: Int, top: UInt32, bottom: UInt32) -> [UInt8] {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func color(_ c: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255,
                blue: CGFloat(c & 0xFF) / 255, alpha: 1)
    }
    // CoreGraphics' origin is bottom-left: the upper half is y ≥ height/2.
    ctx.setFillColor(color(top))
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    ctx.setFillColor(color(bottom))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return [UInt8](data as Data)
}

func channels(_ pixel: UInt32?) -> (r: Int, g: Int, b: Int)? {
    guard let p = pixel else { return nil }
    return (Int((p >> 16) & 0xFF), Int((p >> 8) & 0xFF), Int(p & 0xFF))
}

func close(_ pixel: UInt32?, to color: UInt32, tolerance: Int) -> Bool {
    guard let a = channels(pixel), let b = channels(color | 0xFF00_0000) else { return false }
    return abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
}

// MARK: - Fake RFB server

/// Messages the fake server parsed from the client.
enum ClientMessage: Equatable, Sendable {
    case setPixelFormat([UInt8])
    case setEncodings([Int32])
    case updateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int)
    case key(keysym: UInt32, down: Bool)
    case pointer(buttons: UInt8, x: Int, y: Int)

    var isUpdateRequest: Bool {
        if case .updateRequest = self { return true }
        return false
    }
    var isInput: Bool {
        switch self {
        case .key, .pointer: true
        default: false
        }
    }
}

/// The server role of RFB over the in-memory transport, byte-exact.
actor FakeRFBServer {
    enum Version: String {
        case v33 = "RFB 003.003\n"
        case v37 = "RFB 003.007\n"
        case v38 = "RFB 003.008\n"
    }

    nonisolated let transport: any RFBTransport
    private var buffer: [UInt8] = []
    private(set) var messages: [ClientMessage] = []
    private(set) var clientVersion: String?
    private(set) var sharedFlag: UInt8?
    private var collector: Task<Void, Never>?

    init(transport: any RFBTransport) {
        self.transport = transport
    }

    func read(_ n: Int) async throws -> [UInt8] {
        while buffer.count < n { buffer += try await transport.receive() }
        let out = Array(buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }

    func send(_ bytes: [UInt8]) async throws {
        try await transport.send(Data(bytes))
    }

    /// Server handshake up to and including ServerInit.
    func handshake(version: Version = .v38, width: Int = 64, height: Int = 48, name: String = "nebula-agent",
                   securityTypes: [UInt8] = [1]) async throws {
        try await send(Array(version.rawValue.utf8))
        clientVersion = String(decoding: try await read(12), as: UTF8.self)
        switch version {
        case .v33:
            try await send(Wire.u32(1))
        case .v37, .v38:
            try await send([UInt8(securityTypes.count)] + securityTypes)
            let choice = try await read(1)[0]
            precondition(choice == 1)
            if version == .v38 { try await send(Wire.u32(0)) }
        }
        sharedFlag = try await read(1)[0]
        let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        let nameBytes = Array(name.utf8)
        var serverInit = Wire.u16(width)
        serverInit += Wire.u16(height)
        serverInit += format
        serverInit += Wire.u32(UInt32(nameBytes.count))
        serverInit += nameBytes
        try await send(serverInit)
    }

    func readMessage() async throws -> ClientMessage {
        let type = try await read(1)[0]
        switch type {
        case 0:
            let b = try await read(19)
            return .setPixelFormat(Array(b[3..<19]))
        case 2:
            let b = try await read(3)
            let count = Int(b[1]) << 8 | Int(b[2])
            let raw = try await read(4 * count)
            return .setEncodings((0..<count).map { i in Int32(bitPattern: bigEndian32(raw, at: 4 * i)) })
        case 3:
            let b = try await read(9)
            func v(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
            return .updateRequest(incremental: b[0] != 0, x: v(1), y: v(3), width: v(5), height: v(7))
        case 4:
            let b = try await read(7)
            return .key(keysym: bigEndian32(b, at: 3), down: b[0] != 0)
        case 5:
            let b = try await read(5)
            return .pointer(buttons: b[0], x: Int(b[1]) << 8 | Int(b[2]), y: Int(b[3]) << 8 | Int(b[4]))
        default:
            throw RFBError.protocolViolation("fake server: client message \(type)")
        }
    }

    /// Reads client messages in the background into `messages`.
    func startCollecting() {
        collector = Task {
            while true {
                do {
                    let m = try await readMessage()
                    messages.append(m)
                } catch {
                    return
                }
            }
        }
    }

    func sendUpdate(_ rects: [[UInt8]], count: Int? = nil) async throws {
        try await send(Wire.update(rects, count: count))
    }

    var updateRequests: [ClientMessage] { messages.filter(\.isUpdateRequest) }
    var inputMessages: [ClientMessage] { messages.filter(\.isInput) }
}

/// A client + fake server pair that has completed the handshake and the client's setup messages.
struct Harness {
    let client: RFBClient
    let server: FakeRFBServer
    let mailbox: FrameMailbox
    let run: Task<Void, any Error>

    static func start(version: FakeRFBServer.Version = .v38, width: Int = 64, height: Int = 48,
                      configuration: RFBClient.Configuration = RFBClient.Configuration()) async throws -> Harness {
        let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
        let mailbox = FrameMailbox()
        let client = RFBClient(transport: clientEnd, configuration: configuration, mailbox: mailbox)
        let server = FakeRFBServer(transport: serverEnd)
        let run = Task { try await client.run() }
        try await server.handshake(version: version, width: width, height: height)
        await server.startCollecting()
        _ = await eventually { await server.updateRequests.count >= 1 }
        return Harness(client: client, server: server, mailbox: mailbox, run: run)
    }

    /// Sends an update and waits until the client decoded it.
    func apply(_ rects: [[UInt8]], count: Int? = nil) async throws {
        let before = client.metrics.framebufferUpdates
        try await server.sendUpdate(rects, count: count)
        let client = self.client
        let done = await eventually { client.metrics.framebufferUpdates > before }
        if !done {
            // Surface the client's error if it failed.
            run.cancel()
            _ = try await run.value
        }
    }

    /// Sends bytes and returns the error the client run ended with.
    func expectFailure(_ bytes: [UInt8]) async -> (any Error)? {
        try? await server.send(bytes)
        // Never hang a test: a client still waiting for data after 3 s gets its pipe closed.
        let transport = server.transport
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            transport.close()
        }
        defer { watchdog.cancel() }
        do {
            try await run.value
            return nil
        } catch {
            return error
        }
    }

    func stop() {
        client.close()
        run.cancel()
    }
}

// MARK: - Session fakes

actor FakeBackend: LiveDesktopBackend {
    private(set) var calls: [String] = []
    private(set) var connectCount = 0
    var connectError: (any Error)?
    var acquireError: LiveBackendError?
    var acquireResult = true
    var renewResult = true

    func setConnectError(_ e: (any Error)?) { connectError = e }
    func setAcquireError(_ e: LiveBackendError?) { acquireError = e }
    func setRenewResult(_ r: Bool) { renewResult = r }

    func connect(agentID: String) async throws -> LiveConnectInfo {
        connectCount += 1
        calls.append("connect")
        if let connectError { throw connectError }
        return LiveConnectInfo(sessionID: "s\(connectCount)",
                               webSocketURL: URL(string: "wss://gateway.invalid/api/v1/live/ws/s\(connectCount)")!,
                               expiresAt: Date().addingTimeInterval(90))
    }

    func control(sessionID: String, action: LiveControlAction) async throws -> Bool {
        calls.append("\(action.rawValue):\(sessionID)")
        switch action {
        case .acquire:
            if let acquireError { throw acquireError }
            return acquireResult
        case .renew:
            return renewResult
        case .release:
            return false
        }
    }

    func disconnect(sessionID: String) async {
        calls.append("disconnect:\(sessionID)")
    }

    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
}

/// Creates a fake server per connect (keyed by session id); each completes the handshake and sends one update.
final class ServerHub: Sendable {
    private let servers = Mutex<[String: FakeRFBServer]>([:])

    var factory: LiveDesktopSession.TransportFactory {
        { [self] info in self.make(info) }
    }

    func make(_ info: LiveConnectInfo) -> any RFBTransport {
        let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
        let server = FakeRFBServer(transport: serverEnd)
        servers.withLock { $0[info.sessionID] = server }
        Task {
            do {
                try await server.handshake(width: 32, height: 24)
                await server.startCollecting()
                try await server.sendUpdate([Wire.tightFill(0, 0, 32, 24, 0x336699)])
            } catch {}
        }
        return clientEnd
    }

    func server(_ id: String) -> FakeRFBServer? { servers.withLock { $0[id] } }
}

/// The SetEncodings list the client must send (Tight, ZRLE, CopyRect, Raw, pseudo-encodings, quality, level 6).
func expectedEncodings(quality: Int32) -> [Int32] {
    let base: [Int32] = [7, 16, 1, 0, -223, -308, -224]
    return base + [-32 + quality, -250]
}
