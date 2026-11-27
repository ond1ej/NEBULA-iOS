import Foundation

// RFB ("VNC") wire format, RFC 6143 plus the Tight / ZRLE / pseudo-encoding extensions TigerVNC speaks.
// Everything here is pure data: no I/O, no state.

/// Errors raised by the RFB client. A malformed, truncated or hostile byte stream always ends in one of these
/// (never in a crash, an overflow or an unbounded allocation).
public enum RFBError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server's ProtocolVersion line is not a supported RFB 3.x version.
    case unsupportedVersion(String)
    /// The server refused the connection (security type 0 / SecurityResult failed), with its reason.
    case securityFailure(String)
    /// The server offers no security type this client supports (only "None" is supported: the gateway authenticates).
    case unsupportedSecurityTypes([UInt8])
    /// The stream violates the protocol (unknown message, bad sub-encoding, inconsistent sizes…).
    case protocolViolation(String)
    /// A rectangle uses an encoding the client did not ask for.
    case unsupportedEncoding(Int32)
    /// A desktop size of zero or above the configured cap.
    case invalidFramebufferSize(width: Int, height: Int)
    /// A rectangle (or a CopyRect source) outside the framebuffer.
    case rectOutOfBounds(x: Int, y: Int, width: Int, height: Int)
    /// Less data than a structure requires.
    case truncated(String)
    /// A palette index beyond the palette (Tight palette filter, ZRLE packed/RLE palettes).
    case paletteIndexOutOfRange
    /// zlib reported an error or the inflated size does not match.
    case decompressionFailed(String)
    /// A Tight JPEG rectangle could not be decoded.
    case imageDecodingFailed
    /// A length field above the safety limits.
    case messageTooLarge(Int)
    /// `run()` was called twice on the same client.
    case alreadyStarted

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "unsupported RFB version \(v)"
        case .securityFailure(let r): "server refused the connection: \(r)"
        case .unsupportedSecurityTypes(let t): "no supported security type (server offers \(t))"
        case .protocolViolation(let m): "RFB protocol violation: \(m)"
        case .unsupportedEncoding(let e): "unsupported rectangle encoding \(e)"
        case .invalidFramebufferSize(let w, let h): "invalid desktop size \(w)x\(h)"
        case .rectOutOfBounds(let x, let y, let w, let h): "rectangle \(w)x\(h)+\(x)+\(y) outside the desktop"
        case .truncated(let m): "truncated data: \(m)"
        case .paletteIndexOutOfRange: "palette index out of range"
        case .decompressionFailed(let m): "decompression failed: \(m)"
        case .imageDecodingFailed: "JPEG rectangle could not be decoded"
        case .messageTooLarge(let n): "message of \(n) bytes exceeds the safety limit"
        case .alreadyStarted: "the RFB client is already running"
        }
    }
}

/// An RFB protocol version ("RFB 003.008\n").
public struct RFBVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let v3_3 = RFBVersion(major: 3, minor: 3)
    public static let v3_7 = RFBVersion(major: 3, minor: 7)
    public static let v3_8 = RFBVersion(major: 3, minor: 8)

    public var description: String { "\(major).\(minor)" }

    public static func < (a: RFBVersion, b: RFBVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    /// Parses the 12-byte ProtocolVersion message strictly.
    static func parse(_ bytes: [UInt8]) throws -> RFBVersion {
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                let b = bytes[i]
                guard b >= 0x30, b <= 0x39 else { return nil }
                value = value * 10 + Int(b - 0x30)
            }
            return value
        }
        let printable = String(decoding: bytes.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x3F }, as: UTF8.self)
        guard bytes.count == 12, Array(bytes[0..<4]) == Array("RFB ".utf8), bytes[7] == 0x2E, bytes[11] == 0x0A,
              let major = digits(4..<7), let minor = digits(8..<11)
        else { throw RFBError.unsupportedVersion(printable) }
        return RFBVersion(major: major, minor: minor)
    }

    /// The version this client answers with: 3.8 for 3.8 and newer (incl. Apple's 3.889), 3.7, or 3.3 for 3.3–3.6.
    func negotiated() throws -> RFBVersion {
        if major > 3 { return .v3_8 }
        guard major == 3, minor >= 3 else { throw RFBError.unsupportedVersion(description) }
        if minor >= 8 { return .v3_8 }
        if minor == 7 { return .v3_7 }
        return .v3_3
    }

    /// The ProtocolVersion bytes for this version.
    var handshake: [UInt8] {
        func three(_ v: Int) -> [UInt8] {
            let c = min(max(v, 0), 999)
            return [UInt8(0x30 + c / 100), UInt8(0x30 + (c / 10) % 10), UInt8(0x30 + c % 10)]
        }
        return Array("RFB ".utf8) + three(major) + [0x2E] + three(minor) + [0x0A]
    }
}

/// The RFB PIXEL_FORMAT structure.
public struct RFBPixelFormat: Sendable, Equatable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColour: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    /// 32-bit true colour, little-endian, 0x00RRGGBB: in memory B, G, R, X, which maps 1:1 onto a CGImage with
    /// `byteOrder32Little | noneSkipFirst`. Tight TPIXEL and ZRLE CPIXEL are 3 bytes in this format.
    public static let bgrx32 = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
                                              redMax: 255, greenMax: 255, blueMax: 255,
                                              redShift: 16, greenShift: 8, blueShift: 0)

    var encoded: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColour ? 1 : 0,
         UInt8(redMax >> 8), UInt8(redMax & 0xFF), UInt8(greenMax >> 8), UInt8(greenMax & 0xFF),
         UInt8(blueMax >> 8), UInt8(blueMax & 0xFF), redShift, greenShift, blueShift, 0, 0, 0]
    }

    static func decode(_ b: [UInt8]) -> RFBPixelFormat? {
        guard b.count >= 16 else { return nil }
        return RFBPixelFormat(bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColour: b[3] != 0,
                              redMax: UInt16(b[4]) << 8 | UInt16(b[5]), greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
                              blueMax: UInt16(b[8]) << 8 | UInt16(b[9]), redShift: b[10], greenShift: b[11],
                              blueShift: b[12])
    }
}

/// Rectangle encodings and pseudo-encodings.
public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let tight: Int32 = 7
    public static let zrle: Int32 = 16
    public static let desktopSize: Int32 = -223
    public static let lastRect: Int32 = -224
    public static let cursor: Int32 = -239
    public static let extendedDesktopSize: Int32 = -308

    /// Tight JPEG quality pseudo-encoding (-32 … -23) for a level 0…9.
    public static func jpegQuality(_ level: Int) -> Int32 { -32 + Int32(min(max(level, 0), 9)) }
    /// Compression level pseudo-encoding (-256 … -247) for a level 0…9.
    public static func compressionLevel(_ level: Int) -> Int32 { -256 + Int32(min(max(level, 0), 9)) }
}

/// The RFB pointer button mask.
public struct RFBPointerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left = RFBPointerButtons(rawValue: 1)
    public static let middle = RFBPointerButtons(rawValue: 2)
    public static let right = RFBPointerButtons(rawValue: 4)
    public static let wheelUp = RFBPointerButtons(rawValue: 8)
    public static let wheelDown = RFBPointerButtons(rawValue: 16)
    public static let wheelLeft = RFBPointerButtons(rawValue: 32)
    public static let wheelRight = RFBPointerButtons(rawValue: 64)

    /// The buttons that stay pressed (wheel "buttons" are always clicked: press + release).
    public static let held: RFBPointerButtons = [.left, .middle, .right]
}

/// Client → server message builders (byte-exact; the NEBULA proxy parses these to filter input).
enum RFBClientMessage {
    static func setPixelFormat(_ format: RFBPixelFormat) -> [UInt8] {
        [0, 0, 0, 0] + format.encoded
    }

    static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        let count = UInt16(min(encodings.count, Int(UInt16.max)))
        var out: [UInt8] = [2, 0, UInt8(count >> 8), UInt8(count & 0xFF)]
        out.reserveCapacity(4 + 4 * Int(count))
        for e in encodings.prefix(Int(count)) { out.appendBE(UInt32(bitPattern: e)) }
        return out
    }

    static func framebufferUpdateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = [3, incremental ? 1 : 0]
        out.appendBE(UInt16(clamping: x))
        out.appendBE(UInt16(clamping: y))
        out.appendBE(UInt16(clamping: width))
        out.appendBE(UInt16(clamping: height))
        return out
    }

    static func keyEvent(keysym: UInt32, down: Bool) -> [UInt8] {
        var out: [UInt8] = [4, down ? 1 : 0, 0, 0]
        out.appendBE(keysym)
        return out
    }

    static func pointerEvent(buttons: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        var out: [UInt8] = [5, buttons]
        out.appendBE(x)
        out.appendBE(y)
        return out
    }
}

extension Array where Element == UInt8 {
    mutating func appendBE(_ v: UInt16) {
        append(UInt8(v >> 8))
        append(UInt8(v & 0xFF))
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8(v >> 24))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}

extension Data {
    mutating func appendBE(_ v: UInt16) {
        append(UInt8(v >> 8))
        append(UInt8(v & 0xFF))
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8(v >> 24))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}
