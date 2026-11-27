import Foundation

/// ZRLE (encoding 16): one persistent zlib stream for the connection; the inflated data is a sequence of 64×64
/// tiles (raw, solid, packed palette, plain RLE, palette RLE).
///
/// In the client's pixel format (32 bpp little-endian, depth 24, colours in the low 3 bytes) a CPIXEL is 3 bytes in
/// wire order B, G, R.
final class ZRLEDecoder {
    static let tileSize = 64
    /// Upper bound for one rectangle's compressed payload.
    static let maximumCompressedLength = 32 << 20

    private let stream = InflateStream()
    private let scratch = ScratchBuffer(capacity: 256 * 1024)
    private var palette: [UInt32] = Array(repeating: 0, count: 128)

    /// Largest legitimate inflated size for a rectangle (raw tiles and worst-case RLE are bounded per pixel).
    static func inflatedLimit(width w: Int, height h: Int) -> Int {
        let tiles = ((w + tileSize - 1) / tileSize) * ((h + tileSize - 1) / tileSize)
        return w * h * 4 + tiles * (1 + 127 * 3) + 1024
    }

    func decode(_ compressed: UnsafeRawBufferPointer, x: Int, y: Int, width w: Int, height h: Int,
                into fb: Framebuffer) throws {
        guard w > 0, h > 0 else {
            // Still feed the stream so its dictionary stays in sync with the server's.
            _ = try stream.inflateAll(compressed, into: scratch, limit: 1024)
            return
        }
        let produced = try stream.inflateAll(compressed, into: scratch, limit: Self.inflatedLimit(width: w, height: h))
        var cursor = ByteCursor(scratch.bytes(produced))
        var ty = 0
        while ty < h {
            let th = min(Self.tileSize, h - ty)
            var tx = 0
            while tx < w {
                let tw = min(Self.tileSize, w - tx)
                try decodeTile(&cursor, x: x + tx, y: y + ty, width: tw, height: th, into: fb)
                tx += Self.tileSize
            }
            ty += Self.tileSize
        }
        guard cursor.remaining == 0 else { throw RFBError.protocolViolation("ZRLE: \(cursor.remaining) trailing bytes") }
        fb.markDirty(x: x, y: y, width: w, height: h)
    }

    @inline(__always)
    private static func cpixel(_ c: inout ByteCursor) throws -> UInt32 {
        let b = try c.u8(), g = try c.u8(), r = try c.u8()
        return bgrxPixel(r: r, g: g, b: b)
    }

    private static func runLength(_ c: inout ByteCursor, limit: Int) throws -> Int {
        var length = 1
        while true {
            let b = try c.u8()
            length += Int(b)
            guard length <= limit else { throw RFBError.protocolViolation("ZRLE run beyond the tile") }
            if b != 255 { return length }
        }
    }

    /// Writes `count` pixels starting at tile-local linear index `start` (row-major within the tile).
    @inline(__always)
    private static func run(_ pixel: UInt32, start: Int, count: Int, x: Int, y: Int, tileWidth tw: Int,
                            into fb: Framebuffer) {
        var index = start
        var left = count
        while left > 0 {
            let r = index / tw, c = index % tw
            let n = min(left, tw - c)
            (fb.row(y + r) + x + c).update(repeating: pixel, count: n)
            index += n
            left -= n
        }
    }

    private func decodeTile(_ c: inout ByteCursor, x: Int, y: Int, width tw: Int, height th: Int,
                            into fb: Framebuffer) throws {
        let sub = try c.u8()
        let total = tw * th
        switch sub {
        case 0: // raw CPIXELs
            let raw = try c.take(total * 3)
            var s = 0
            for r in 0..<th {
                let dst = fb.row(y + r) + x
                for col in 0..<tw {
                    dst[col] = bgrxPixel(r: raw[s + 2], g: raw[s + 1], b: raw[s])
                    s += 3
                }
            }
        case 1: // solid
            let p = try Self.cpixel(&c)
            for r in 0..<th { (fb.row(y + r) + x).update(repeating: p, count: tw) }
        case 2...16: // packed palette
            let size = Int(sub)
            for i in 0..<size { palette[i] = try Self.cpixel(&c) }
            let bits = size == 2 ? 1 : (size <= 4 ? 2 : 4)
            let rowBytes = (tw * bits + 7) / 8
            let packed = try c.take(rowBytes * th)
            let mask = UInt8((1 << bits) - 1)
            for r in 0..<th {
                let dst = fb.row(y + r) + x
                let rowStart = r * rowBytes
                var bitOffset = 0
                for col in 0..<tw {
                    let byte = packed[rowStart + (bitOffset >> 3)]
                    let shift = 8 - bits - (bitOffset & 7)
                    let index = Int((byte >> UInt8(shift)) & mask)
                    guard index < size else { throw RFBError.paletteIndexOutOfRange }
                    dst[col] = palette[index]
                    bitOffset += bits
                }
            }
        case 128: // plain RLE
            var index = 0
            while index < total {
                let p = try Self.cpixel(&c)
                let length = try Self.runLength(&c, limit: total - index)
                Self.run(p, start: index, count: length, x: x, y: y, tileWidth: tw, into: fb)
                index += length
            }
        case 130...255: // palette RLE
            let size = Int(sub) - 128
            for i in 0..<size { palette[i] = try Self.cpixel(&c) }
            var index = 0
            while index < total {
                let b = try c.u8()
                let paletteIndex = Int(b & 0x7F)
                guard paletteIndex < size else { throw RFBError.paletteIndexOutOfRange }
                let length = b & 0x80 != 0 ? try Self.runLength(&c, limit: total - index) : 1
                Self.run(palette[paletteIndex], start: index, count: length, x: x, y: y, tileWidth: tw, into: fb)
                index += length
            }
        default:
            throw RFBError.protocolViolation("ZRLE sub-encoding \(sub)")
        }
    }
}
