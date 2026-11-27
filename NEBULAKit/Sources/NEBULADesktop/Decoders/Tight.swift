import CoreGraphics
import Foundation
import ImageIO

/// The synchronous parts of the Tight decoder (encoding 7): four persistent zlib streams, the Copy / Palette /
/// Gradient filters and JPEG. The byte-stream parsing (which needs to await more data) lives in `RFBClient`.
///
/// In the client's pixel format (32 bpp, depth 24, 8-bit channels) a TPIXEL is 3 bytes: R, G, B.
final class TightDecoder {
    /// Data shorter than this is sent uncompressed (no length, no zlib).
    static let minimumCompressedSize = 12
    /// Upper bound for one rectangle's filtered data (TigerVNC splits Tight rectangles far below this).
    static let maximumDataSize = 64 << 20
    /// Upper bound for one compact length (the 3-byte compact representation tops out at 4 MiB).
    static let maximumCompactLength = (1 << 22) - 1

    private let streams = [InflateStream(), InflateStream(), InflateStream(), InflateStream()]
    private let scratch = ScratchBuffer(capacity: 256 * 1024)
    private var gradientRows: [UInt8] = []
    private(set) var palette: [UInt32] = Array(repeating: 0, count: 256)
    private(set) var paletteCount = 0

    enum Filter: UInt8 { case copy = 0, palette = 1, gradient = 2 }

    /// Applies the reset bits (bits 0–3 of the compression-control byte).
    func resetStreams(_ mask: UInt8) {
        for i in 0..<4 where mask & (1 << UInt8(i)) != 0 { streams[i].reset() }
    }

    /// Size of the filtered data of a basic-compression rectangle.
    static func dataSize(filter: Filter, width: Int, height: Int, paletteCount: Int) -> Int {
        switch filter {
        case .copy, .gradient: return width * height * 3
        case .palette: return (paletteCount == 2 ? (width + 7) / 8 : width) * height
        }
    }

    func setPalette(_ bytes: UnsafeRawBufferPointer, count: Int) {
        let count = min(count, 256, bytes.count / 3)
        paletteCount = count
        for i in 0..<count {
            palette[i] = bgrxPixel(r: bytes[i * 3], g: bytes[i * 3 + 1], b: bytes[i * 3 + 2])
        }
    }

    /// Inflates a basic-compression payload on stream `id` into the scratch buffer.
    func inflate(stream id: Int, input: UnsafeRawBufferPointer, size: Int) throws -> UnsafeRawBufferPointer {
        guard (0..<4).contains(id) else { throw RFBError.protocolViolation("Tight stream \(id)") }
        guard size <= Self.maximumDataSize else { throw RFBError.messageTooLarge(size) }
        scratch.reserve(size)
        try streams[id].inflate(input, into: UnsafeMutableRawBufferPointer(start: scratch.base, count: size))
        return scratch.bytes(size)
    }

    /// Writes filtered data into the framebuffer rectangle (already validated).
    func apply(filter: Filter, data: UnsafeRawBufferPointer, x: Int, y: Int, width w: Int, height h: Int,
               into fb: Framebuffer) throws {
        guard w > 0, h > 0 else { return }
        guard data.count >= Self.dataSize(filter: filter, width: w, height: h, paletteCount: paletteCount) else {
            throw RFBError.truncated("Tight rectangle data")
        }
        switch filter {
        case .copy:
            for r in 0..<h {
                let dst = fb.row(y + r) + x
                var s = r * w * 3
                for c in 0..<w {
                    dst[c] = bgrxPixel(r: data[s], g: data[s + 1], b: data[s + 2])
                    s += 3
                }
            }
        case .palette:
            if paletteCount == 2 {
                let rowBytes = (w + 7) / 8
                let p0 = palette[0], p1 = palette[1]
                for r in 0..<h {
                    let dst = fb.row(y + r) + x
                    let rowStart = r * rowBytes
                    for c in 0..<w {
                        let bit = (data[rowStart + (c >> 3)] >> (7 - UInt8(c & 7))) & 1
                        dst[c] = bit == 0 ? p0 : p1
                    }
                }
            } else {
                let count = paletteCount
                for r in 0..<h {
                    let dst = fb.row(y + r) + x
                    let rowStart = r * w
                    for c in 0..<w {
                        let index = Int(data[rowStart + c])
                        guard index < count else { throw RFBError.paletteIndexOutOfRange }
                        dst[c] = palette[index]
                    }
                }
            }
        case .gradient:
            applyGradient(data, x: x, y: y, width: w, height: h, into: fb)
        }
        fb.markDirty(x: x, y: y, width: w, height: h)
    }

    /// The Tight gradient filter: each component is predicted as clamp(left + up − upLeft) and the data holds
    /// the difference modulo 256 (identical to TigerVNC's FilterGradient24).
    private func applyGradient(_ data: UnsafeRawBufferPointer, x: Int, y: Int, width w: Int, height h: Int,
                               into fb: Framebuffer) {
        let rowLength = w * 3
        gradientRows.removeAll(keepingCapacity: true)
        gradientRows.append(contentsOf: repeatElement(0, count: rowLength * 2))
        gradientRows.withUnsafeMutableBufferPointer { rows in
            var previous = 0
            var current = rowLength
            var s = 0
            for r in 0..<h {
                let dst = fb.row(y + r) + x
                for c in 0..<w {
                    let o = c * 3
                    for k in 0..<3 {
                        let up = Int(rows[previous + o + k])
                        let left = c > 0 ? Int(rows[current + o - 3 + k]) : 0
                        let upLeft = c > 0 ? Int(rows[previous + o - 3 + k]) : 0
                        let estimate = min(max(up + left - upLeft, 0), 255)
                        rows[current + o + k] = UInt8(truncatingIfNeeded: Int(data[s]) + estimate)
                        s += 1
                    }
                    dst[c] = bgrxPixel(r: rows[current + o], g: rows[current + o + 1], b: rows[current + o + 2])
                }
                swap(&previous, &current)
            }
        }
    }

    /// Decodes a Tight JPEG rectangle with ImageIO (on the caller's executor, never the main thread) and draws it.
    func decodeJPEG(_ data: UnsafeRawBufferPointer, x: Int, y: Int, width w: Int, height h: Int,
                    into fb: Framebuffer) throws {
        guard let base = data.baseAddress, data.count > 0 else { throw RFBError.imageDecodingFailed }
        let bytes = Data(bytes: base, count: data.count)
        let sourceOptions = [kCGImageSourceTypeIdentifierHint: "public.jpeg" as CFString,
                             kCGImageSourceShouldCache: false] as CFDictionary
        let imageOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, imageOptions)
        else { throw RFBError.imageDecodingFailed }
        guard image.width == w, image.height == h else {
            throw RFBError.protocolViolation("JPEG is \(image.width)x\(image.height), rectangle \(w)x\(h)")
        }
        try fb.draw(image, x: x, y: y)
    }
}
