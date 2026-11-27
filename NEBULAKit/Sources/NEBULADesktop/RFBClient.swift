import CoreGraphics
import Dispatch
import Foundation

/// What the server announced in ServerInit.
public struct RFBServerInfo: Sendable, Equatable {
    /// The negotiated protocol version (3.3, 3.7 or 3.8).
    public let protocolVersion: RFBVersion
    /// The desktop name (bounded, lossy UTF-8).
    public let name: String
    public let width: Int
    public let height: Int
}

/// Notifications from a running client.
public enum RFBClientEvent: Sendable {
    /// Handshake complete; updates start flowing.
    case connected(RFBServerInfo)
    /// The first FramebufferUpdate was decoded.
    case firstUpdate
    /// The desktop size changed (DesktopSize / ExtendedDesktopSize).
    case desktopResized(width: Int, height: Int)
    /// The remote cursor shape changed (only with `requestCursorShape`); nil = hidden cursor.
    case cursorShape(RemoteCursor?)
    /// The server rang the bell.
    case bell
}

/// An RFB 3.8 viewer (also talks to 3.3 / 3.7 servers) for NEBULA's agent desktops.
///
/// All parsing and decoding runs on the actor's own serial dispatch queue (never on the main thread). Updates are
/// pipelined with exactly one outstanding FramebufferUpdateRequest: the next one goes out as soon as an update
/// has been decoded. Decoded frames are handed to a `FrameMailbox` for the renderer.
///
/// Security boundary: ServerCutText (the agent's clipboard) is read and discarded, never surfaced; input is sent
/// only through `input` while it is enabled.
public actor RFBClient {
    public struct Configuration: Sendable, Equatable {
        /// Tight JPEG quality 0…9 (the "image quality" setting).
        public var jpegQuality: Int
        /// zlib compression level 0…9 requested from the server.
        public var compressionLevel: Int
        /// Ask for the Cursor pseudo-encoding (the server then no longer draws the pointer into the framebuffer).
        public var requestCursorShape: Bool
        /// Desktop sizes above this (either side) are rejected.
        public var maximumDimension: Int
        /// Desktop sizes above this many pixels are rejected (memory bound: 4 bytes per pixel plus snapshots).
        public var maximumPixels: Int
        /// Do not request updates until `setPaused(false)`.
        public var startsPaused: Bool

        public init(jpegQuality: Int = 7, compressionLevel: Int = 6, requestCursorShape: Bool = false,
                    maximumDimension: Int = 8192, maximumPixels: Int = 16_777_216, startsPaused: Bool = false) {
            self.jpegQuality = min(max(jpegQuality, 0), 9)
            self.compressionLevel = min(max(compressionLevel, 0), 9)
            self.requestCursorShape = requestCursorShape
            self.maximumDimension = min(max(maximumDimension, 1), 8192)
            self.maximumPixels = max(maximumPixels, 1)
            self.startsPaused = startsPaused
        }

        /// SetEncodings, in preference order.
        public var encodings: [Int32] {
            var list: [Int32] = [RFBEncoding.tight, RFBEncoding.zrle, RFBEncoding.copyRect, RFBEncoding.raw,
                                 RFBEncoding.desktopSize, RFBEncoding.extendedDesktopSize, RFBEncoding.lastRect,
                                 RFBEncoding.jpegQuality(jpegQuality), RFBEncoding.compressionLevel(compressionLevel)]
            if requestCursorShape { list.append(RFBEncoding.cursor) }
            return list
        }
    }

    /// Bytes buffered for one structure at most (Tight compact lengths are ≤ 4 MiB, ZRLE is capped at 32 MiB).
    static let maximumBufferedBytes = 40 << 20
    /// ServerCutText larger than this is treated as a protocol violation (it is discarded anyway).
    static let maximumCutText = 64 << 20

    private let queue = DispatchSerialQueue(label: "nebula.live.rfb", qos: .userInteractive)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Client events (finishes when `run()` returns).
    public nonisolated let events: AsyncStream<RFBClientEvent>
    /// The input channel; enable it only while the control lease is held.
    public nonisolated let input: RFBInputQueue
    /// Byte / update counters.
    public nonisolated let metrics = RFBMetrics()

    private let eventContinuation: AsyncStream<RFBClientEvent>.Continuation
    private let transport: any RFBTransport
    private let mailbox: FrameMailbox?
    private var configuration: Configuration

    private var buffer = ByteBuffer()
    private var framebuffer: Framebuffer?
    private let tight = TightDecoder()
    private let zrle = ZRLEDecoder()

    private var started = false
    private var running = false
    private var paused: Bool
    private var pauseSequence: UInt64 = 0
    private var updateOutstanding = false
    private var fullRefreshPending = true
    private var inUpdate = false
    private var receivedFirstUpdate = false

    public init(transport: any RFBTransport, configuration: Configuration = Configuration(),
                mailbox: FrameMailbox? = nil, input: RFBInputQueue = RFBInputQueue()) {
        self.transport = transport
        self.configuration = configuration
        self.mailbox = mailbox
        self.input = input
        paused = configuration.startsPaused
        (events, eventContinuation) = AsyncStream.makeStream(of: RFBClientEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    /// Performs the handshake and processes server messages until the connection ends. Always throws at the end
    /// (`RFBTransportError` for a closed/failed pipe, `RFBError` for a protocol problem, `CancellationError`).
    public func run() async throws {
        guard !started else { throw RFBError.alreadyStarted }
        started = true
        var pump: Task<Void, Never>?
        defer {
            pump?.cancel()
            shutdown()
        }
        let info = try await handshake()
        try await sendSetup()
        running = true
        mailbox?.attachProducer(ObjectIdentifier(self)) { [weak self] in
            guard let self else { return }
            Task { await self.publishPendingFrame() }
        }
        eventContinuation.yield(.connected(info))
        pump = startInputPump()
        try await messageLoop()
    }

    /// Closes the connection (the running `run()` ends with an error). Safe from any thread, idempotent.
    public nonisolated func close() {
        input.close()
        transport.close()
    }

    private func shutdown() {
        running = false
        input.close()
        transport.close()
        mailbox?.detachProducer(ObjectIdentifier(self))
        eventContinuation.finish()
    }

    private func startInputPump() -> Task<Void, Never> {
        let input = self.input
        let transport = self.transport
        return Task.detached(priority: .userInitiated) {
            while let batch = await input.nextBatch() {
                // Re-check right before sending: control may have ended while the batch was being formed.
                guard input.isEnabled else {
                    input.batchCompleted()
                    continue
                }
                do {
                    try await transport.send(batch)
                } catch {
                    input.close()
                    break
                }
                input.batchCompleted()
            }
        }
    }

    // MARK: - Commands

    /// Pauses (stop requesting updates; the renderer idles) or resumes (requests a full, non-incremental update).
    /// `sequence` orders calls coming from different tasks: an older sequence than the last applied is ignored.
    public func setPaused(_ paused: Bool, sequence: UInt64? = nil) async throws {
        if let sequence {
            guard sequence > pauseSequence else { return }
            pauseSequence = sequence
        }
        guard paused != self.paused else { return }
        self.paused = paused
        if !paused {
            fullRefreshPending = true
            // Before setup completes the initial request is sent by the handshake itself (after SetPixelFormat).
            if running { try await requestUpdateIfNeeded() }
        }
    }

    /// Changes the Tight JPEG quality (re-sends SetEncodings and refreshes the whole screen).
    public func setJPEGQuality(_ quality: Int) async throws {
        let q = min(max(quality, 0), 9)
        guard q != configuration.jpegQuality else { return }
        configuration.jpegQuality = q
        guard running else { return }
        try await transport.send(Data(RFBClientMessage.setEncodings(configuration.encodings)))
        try await requestFullRefresh()
    }

    /// Requests a full non-incremental update (after the outstanding one, if any).
    public func requestFullRefresh() async throws {
        fullRefreshPending = true
        guard running else { return }
        try await requestUpdateIfNeeded()
    }

    /// The current desktop size (nil before ServerInit).
    public var desktopSize: (width: Int, height: Int)? {
        framebuffer.map { ($0.width, $0.height) }
    }

    /// One framebuffer pixel as 0xFFRRGGBB (diagnostics and tests).
    public func pixel(x: Int, y: Int) -> UInt32? {
        framebuffer?.pixel(x: x, y: y)
    }

    // MARK: - Reading

    private func need(_ count: Int) async throws {
        guard count <= Self.maximumBufferedBytes else { throw RFBError.messageTooLarge(count) }
        while buffer.count < count {
            try Task.checkCancellation()
            let chunk = try await transport.receive()
            guard !chunk.isEmpty else { continue }
            metrics.addBytes(chunk.count)
            buffer.append(chunk)
        }
    }

    private func readU8() async throws -> UInt8 {
        try await need(1)
        return try buffer.readU8()
    }

    private func readU16() async throws -> UInt16 {
        try await need(2)
        return try buffer.readU16()
    }

    private func readU32() async throws -> UInt32 {
        try await need(4)
        return try buffer.readU32()
    }

    private func readBytes(_ n: Int) async throws -> [UInt8] {
        try await need(n)
        return try buffer.readBytes(n)
    }

    /// Discards `n` bytes as they arrive (without buffering them all).
    private func discard(_ n: Int) async throws {
        var left = n
        while left > 0 {
            let step = min(left, 64 * 1024)
            try await need(step)
            try buffer.skip(step)
            left -= step
        }
    }

    /// A length-prefixed reason string (bounded, lossy UTF-8).
    private func readReason() async throws -> String {
        let length = Int(try await readU32())
        guard length <= 64 * 1024 else { throw RFBError.messageTooLarge(length) }
        return String(decoding: try await readBytes(length), as: UTF8.self)
    }

    /// Tight "compact length": 1–3 bytes, 7 bits each (the third byte contributes 8 bits).
    private func readCompactLength() async throws -> Int {
        let b0 = try await readU8()
        var length = Int(b0 & 0x7F)
        if b0 & 0x80 != 0 {
            let b1 = try await readU8()
            length |= Int(b1 & 0x7F) << 7
            if b1 & 0x80 != 0 {
                length |= Int(try await readU8()) << 14
            }
        }
        return length
    }

    // MARK: - Handshake

    private func handshake() async throws -> RFBServerInfo {
        let version = try RFBVersion.parse(try await readBytes(12)).negotiated()
        try await transport.send(Data(version.handshake))

        if version == .v3_3 {
            switch try await readU32() {
            case 0: throw RFBError.securityFailure(try await readReason())
            case 1: break
            case let other: throw RFBError.unsupportedSecurityTypes([UInt8(clamping: other)])
            }
        } else {
            let count = Int(try await readU8())
            guard count > 0 else { throw RFBError.securityFailure(try await readReason()) }
            let types = try await readBytes(count)
            guard types.contains(1) else { throw RFBError.unsupportedSecurityTypes(types) }
            try await transport.send(Data([1]))
            if version >= .v3_8 {
                // 3.8 sends SecurityResult even for None; 3.7 does not.
                if try await readU32() != 0 { throw RFBError.securityFailure(try await readReason()) }
            }
        }

        try await transport.send(Data([1])) // ClientInit: shared — the agent and other viewers stay connected
        try await need(24)
        let width = Int(try buffer.readU16())
        let height = Int(try buffer.readU16())
        try buffer.skip(16) // the server's pixel format; ours is set right after
        let nameLength = Int(try buffer.readU32())
        guard nameLength <= 1 << 20 else { throw RFBError.messageTooLarge(nameLength) }
        let nameBytes = try await readBytes(nameLength)
        let name = String(decoding: nameBytes.prefix(256), as: UTF8.self)
        try validateSize(width: width, height: height)
        framebuffer = Framebuffer(width: width, height: height)
        return RFBServerInfo(protocolVersion: version, name: name, width: width, height: height)
    }

    private func sendSetup() async throws {
        var setup = RFBClientMessage.setPixelFormat(.bgrx32)
        setup += RFBClientMessage.setEncodings(configuration.encodings)
        try await transport.send(Data(setup))
        fullRefreshPending = true
        try await requestUpdateIfNeeded()
    }

    private func validateSize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= configuration.maximumDimension,
              height <= configuration.maximumDimension, width * height <= configuration.maximumPixels
        else { throw RFBError.invalidFramebufferSize(width: width, height: height) }
    }

    // MARK: - Update requests

    private func requestUpdateIfNeeded() async throws {
        guard !paused, !updateOutstanding, let fb = framebuffer else { return }
        let incremental = !fullRefreshPending
        fullRefreshPending = false
        updateOutstanding = true
        try await transport.send(Data(RFBClientMessage.framebufferUpdateRequest(
            incremental: incremental, x: 0, y: 0, width: fb.width, height: fb.height)))
    }

    // MARK: - Server messages

    private func messageLoop() async throws {
        while true {
            try Task.checkCancellation()
            switch try await readU8() {
            case 0: try await readFramebufferUpdate()
            case 1: // SetColourMapEntries: never used in true colour; skip safely
                try await need(5)
                try buffer.skip(3)
                let count = Int(try buffer.readU16())
                try await discard(count * 6)
            case 2:
                eventContinuation.yield(.bell)
            case 3: // ServerCutText: the agent's clipboard never crosses into the app (security boundary)
                try await need(7)
                try buffer.skip(3)
                let length = Int(try buffer.readS32().magnitude) // negative = extended clipboard, same framing
                guard length <= Self.maximumCutText else { throw RFBError.messageTooLarge(length) }
                try await discard(length)
            case let type:
                throw RFBError.protocolViolation("unknown server message type \(type)")
            }
        }
    }

    private func readFramebufferUpdate() async throws {
        try await need(3)
        try buffer.skip(1)
        let count = Int(try buffer.readU16())
        inUpdate = true
        var rectangles = 0
        rects: while rectangles < count {
            rectangles += 1
            try await need(12)
            let x = Int(try buffer.readU16())
            let y = Int(try buffer.readU16())
            let w = Int(try buffer.readU16())
            let h = Int(try buffer.readU16())
            let encoding = try buffer.readS32()
            switch encoding {
            case RFBEncoding.raw: try await decodeRaw(x: x, y: y, width: w, height: h)
            case RFBEncoding.copyRect: try await decodeCopyRect(x: x, y: y, width: w, height: h)
            case RFBEncoding.tight: try await decodeTight(x: x, y: y, width: w, height: h)
            case RFBEncoding.zrle: try await decodeZRLE(x: x, y: y, width: w, height: h)
            case RFBEncoding.desktopSize: try resize(width: w, height: h)
            case RFBEncoding.extendedDesktopSize: try await decodeExtendedDesktopSize(status: y, width: w, height: h)
            case RFBEncoding.lastRect: break rects
            case RFBEncoding.cursor where configuration.requestCursorShape:
                try await decodeCursor(hotspotX: x, hotspotY: y, width: w, height: h)
            default: throw RFBError.unsupportedEncoding(encoding)
            }
        }
        inUpdate = false
        updateOutstanding = false
        // Pipelining: ask for the next update before spending time on the snapshot.
        try await requestUpdateIfNeeded()
        publishIfNeeded()
        metrics.addUpdate(rectangles: rectangles)
        if !receivedFirstUpdate {
            receivedFirstUpdate = true
            eventContinuation.yield(.firstUpdate)
        }
    }

    private func currentFramebuffer() throws -> Framebuffer {
        guard let fb = framebuffer else { throw RFBError.protocolViolation("update before ServerInit") }
        return fb
    }

    // MARK: - Encodings

    private func decodeRaw(x: Int, y: Int, width w: Int, height h: Int) async throws {
        let fb = try currentFramebuffer()
        try fb.validate(x: x, y: y, width: w, height: h)
        guard w > 0, h > 0 else { return }
        let rowBytes = w * 4
        let rowsPerChunk = max(1, (512 * 1024) / rowBytes)
        var row = 0
        while row < h {
            let rows = min(rowsPerChunk, h - row)
            try await need(rows * rowBytes)
            let top = y + row
            try buffer.withBytes(rows * rowBytes) { src in
                fb.write(x: x, y: top, width: w, height: rows, bgrx: src, sourceBytesPerRow: rowBytes)
            }
            row += rows
        }
    }

    private func decodeCopyRect(x: Int, y: Int, width w: Int, height h: Int) async throws {
        try await need(4)
        let sx = Int(try buffer.readU16())
        let sy = Int(try buffer.readU16())
        let fb = try currentFramebuffer()
        try fb.validate(x: x, y: y, width: w, height: h)
        try fb.validate(x: sx, y: sy, width: w, height: h)
        fb.copy(fromX: sx, fromY: sy, toX: x, toY: y, width: w, height: h)
    }

    // Closures below capture only `let` constants: a captured `var` in this async actor method crashes the Swift 6.2
    // and 6.3 compilers (Xcode 26.x) in the SendNonSendable pass.
    private func decodeTight(x: Int, y: Int, width w: Int, height h: Int) async throws {
        let fb = try currentFramebuffer()
        try fb.validate(x: x, y: y, width: w, height: h)
        let decoder = tight
        let control = try await readU8()
        decoder.resetStreams(control & 0x0F)
        let kind = control >> 4

        switch kind {
        case 0x08: // fill
            let rgb = try await readBytes(3)
            fb.fill(x: x, y: y, width: w, height: h, pixel: bgrxPixel(r: rgb[0], g: rgb[1], b: rgb[2]))
        case 0x09: // JPEG
            let length = try await readCompactLength()
            guard length > 0 else { throw RFBError.truncated("empty Tight JPEG") }
            try await need(length)
            guard w > 0, h > 0 else {
                try buffer.skip(length)
                return
            }
            try buffer.withBytes(length) { jpeg in
                try decoder.decodeJPEG(jpeg, x: x, y: y, width: w, height: h, into: fb)
            }
        case 0x00...0x07: // basic compression
            let streamID = Int(kind & 0x03)
            let filter: TightDecoder.Filter
            if kind & 0x04 != 0 {
                let id = try await readU8()
                guard let f = TightDecoder.Filter(rawValue: id) else {
                    throw RFBError.protocolViolation("Tight filter \(id)")
                }
                filter = f
            } else {
                filter = .copy
            }
            let paletteCount: Int
            if filter == .palette {
                let count = Int(try await readU8()) + 1
                let colours = try await readBytes(count * 3)
                colours.withUnsafeBytes { decoder.setPalette($0, count: count) }
                paletteCount = count
            } else {
                paletteCount = 0
            }
            let size = TightDecoder.dataSize(filter: filter, width: w, height: h, paletteCount: paletteCount)
            guard size <= TightDecoder.maximumDataSize else { throw RFBError.messageTooLarge(size) }
            guard size > 0 else { return }
            if size < TightDecoder.minimumCompressedSize {
                try await need(size)
                try buffer.withBytes(size) { raw in
                    try decoder.apply(filter: filter, data: raw, x: x, y: y, width: w, height: h, into: fb)
                }
            } else {
                let length = try await readCompactLength()
                guard length > 0 else { throw RFBError.truncated("empty Tight zlib payload") }
                try await need(length)
                try buffer.withBytes(length) { compressed in
                    let data = try decoder.inflate(stream: streamID, input: compressed, size: size)
                    try decoder.apply(filter: filter, data: data, x: x, y: y, width: w, height: h, into: fb)
                }
            }
        default:
            // 0x0A is TightPNG (not negotiated), the rest is undefined.
            throw RFBError.protocolViolation("Tight compression type \(kind)")
        }
    }

    private func decodeZRLE(x: Int, y: Int, width w: Int, height h: Int) async throws {
        let fb = try currentFramebuffer()
        try fb.validate(x: x, y: y, width: w, height: h)
        let length = Int(try await readU32())
        guard length <= ZRLEDecoder.maximumCompressedLength else { throw RFBError.messageTooLarge(length) }
        try await need(length)
        let zrle = self.zrle
        try buffer.withBytes(length) { compressed in
            try zrle.decode(compressed, x: x, y: y, width: w, height: h, into: fb)
        }
    }

    /// ExtendedDesktopSize: x = reason, y = status, w×h = new size, then the screen layout (skipped).
    private func decodeExtendedDesktopSize(status: Int, width w: Int, height h: Int) async throws {
        try await need(4)
        let screens = Int(try buffer.readU8())
        try buffer.skip(3)
        try await discard(screens * 16)
        // status ≠ 0 answers a SetDesktopSize we never send: the size did not change.
        if status == 0 { try resize(width: w, height: h) }
    }

    private func decodeCursor(hotspotX: Int, hotspotY: Int, width w: Int, height h: Int) async throws {
        guard w <= CursorDecoder.maximumDimension, h <= CursorDecoder.maximumDimension else {
            throw RFBError.protocolViolation("cursor \(w)x\(h) too large")
        }
        let size = CursorDecoder.payloadSize(width: w, height: h)
        try await need(size)
        let cursor = try buffer.withBytes(size) { payload in
            CursorDecoder.decode(payload, width: w, height: h, hotspotX: hotspotX, hotspotY: hotspotY)
        }
        eventContinuation.yield(.cursorShape(cursor))
    }

    private func resize(width: Int, height: Int) throws {
        try validateSize(width: width, height: height)
        let fb = try currentFramebuffer()
        guard fb.width != width || fb.height != height else { return }
        fb.resize(width: width, height: height)
        fullRefreshPending = true
        eventContinuation.yield(.desktopResized(width: width, height: height))
    }

    // MARK: - Frames

    /// Publishes a snapshot when something changed and the renderer is ready for it (otherwise the mailbox asks
    /// again once the renderer has taken the current frame).
    private func publishIfNeeded() {
        guard let mailbox, let fb = framebuffer, fb.hasDirtyRegion, mailbox.reserveOrDefer() else { return }
        guard let image = fb.makeImage() else { return }
        mailbox.publish(DesktopFrame(image: image, width: fb.width, height: fb.height, dirtyRect: fb.takeDirtyRect()))
    }

    /// The renderer took the previous frame and changes are pending. Mid-update the snapshot waits for the end of
    /// the update (no half-drawn frames).
    private func publishPendingFrame() {
        // Mid-update, the end of the update publishes anyway.
        guard running, !inUpdate else { return }
        publishIfNeeded()
    }
}
