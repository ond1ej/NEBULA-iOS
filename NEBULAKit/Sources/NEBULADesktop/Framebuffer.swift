import CoreGraphics
import Foundation
import Synchronization

/// Packs a colour into the framebuffer's native 32-bit pixel (little-endian B, G, R, X in memory).
@inline(__always)
func bgrxPixel(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
    (0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)).littleEndian
}

/// The remote desktop's pixels, owned exclusively by one `RFBClient` (its decode executor), never shared.
///
/// Storage is 32-bit BGRX rows without padding, so a snapshot maps directly onto a `CGImage`
/// (`byteOrder32Little | noneSkipFirst`). Changed regions are accumulated as a dirty rectangle so the client only
/// publishes a frame when something actually changed.
final class Framebuffer {
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: UnsafeMutableRawPointer
    private var dirty: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
    private var pool: ImageBufferPool

    var bytesPerRow: Int { width * 4 }
    var byteCount: Int { width * height * 4 }
    var hasDirtyRegion: Bool { dirty != nil }

    /// Callers validate the size (`RFBClient` caps it) before creating a framebuffer.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Self.allocate(width * height * 4)
        pool = ImageBufferPool(byteCount: width * height * 4)
    }

    deinit { pixels.deallocate() }

    private static func allocate(_ bytes: Int) -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 4), alignment: 16)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: max(bytes, 4))
        return p
    }

    /// Resizes to a new desktop size (content is cleared to black; the server sends a full update after a resize).
    func resize(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }
        pixels.deallocate()
        self.width = width
        self.height = height
        pixels = Self.allocate(width * height * 4)
        pool = ImageBufferPool(byteCount: width * height * 4)
        markDirty(x: 0, y: 0, width: width, height: height)
    }

    // MARK: - Bounds

    func contains(x: Int, y: Int, width w: Int, height h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x <= width - w && y <= height - h
    }

    func validate(x: Int, y: Int, width w: Int, height h: Int) throws {
        guard contains(x: x, y: y, width: w, height: h) else {
            throw RFBError.rectOutOfBounds(x: x, y: y, width: w, height: h)
        }
    }

    // MARK: - Pixel access (callers validate rectangles first)

    @inline(__always)
    func row(_ y: Int) -> UnsafeMutablePointer<UInt32> {
        (pixels + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
    }

    /// 0xFFRRGGBB (the padding byte is ignored by rendering, so it is normalised here).
    func pixel(x: Int, y: Int) -> UInt32? {
        guard contains(x: x, y: y, width: 1, height: 1) else { return nil }
        return UInt32(littleEndian: row(y)[x]) | 0xFF00_0000
    }

    func fill(x: Int, y: Int, width w: Int, height h: Int, pixel: UInt32) {
        guard w > 0, h > 0 else { return }
        for r in y..<(y + h) { (row(r) + x).update(repeating: pixel, count: w) }
        markDirty(x: x, y: y, width: w, height: h)
    }

    /// Copies `h` rows of `w` native BGRX pixels from `source` (rows of `sourceBytesPerRow`).
    func write(x: Int, y: Int, width w: Int, height h: Int, bgrx source: UnsafeRawBufferPointer,
               sourceBytesPerRow: Int) {
        guard w > 0, h > 0, let base = source.baseAddress, source.count >= (h - 1) * sourceBytesPerRow + w * 4
        else { return }
        for r in 0..<h {
            UnsafeMutableRawPointer(row(y + r) + x).copyMemory(from: base + r * sourceBytesPerRow, byteCount: w * 4)
        }
        markDirty(x: x, y: y, width: w, height: h)
    }

    /// CopyRect: copies a region within the framebuffer; overlapping regions are handled (memmove, row order).
    func copy(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int, width w: Int, height h: Int) {
        guard w > 0, h > 0 else { return }
        // Moving down: copy bottom-up so source rows are read before they are overwritten.
        if dy > sy {
            for r in stride(from: h - 1, through: 0, by: -1) { memmove(row(dy + r) + dx, row(sy + r) + sx, w * 4) }
        } else {
            for r in 0..<h { memmove(row(dy + r) + dx, row(sy + r) + sx, w * 4) }
        }
        markDirty(x: dx, y: dy, width: w, height: h)
    }

    /// Draws a decoded image (Tight JPEG) at (x, y); the image must fit (validated by the caller).
    func draw(_ image: CGImage, x: Int, y: Int) throws {
        guard contains(x: x, y: y, width: image.width, height: image.height), image.width > 0, image.height > 0,
              let ctx = CGContext(data: pixels + y * bytesPerRow + x * 4, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: Self.colorSpace,
                                  bitmapInfo: Self.bitmapInfo.rawValue)
        else { throw RFBError.imageDecodingFailed }
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        markDirty(x: x, y: y, width: image.width, height: image.height)
    }

    // MARK: - Dirty region

    func markDirty(x: Int, y: Int, width w: Int, height h: Int) {
        guard w > 0, h > 0 else { return }
        if let d = dirty {
            dirty = (min(d.minX, x), min(d.minY, y), max(d.maxX, x + w), max(d.maxY, y + h))
        } else {
            dirty = (x, y, x + w, y + h)
        }
    }

    /// Returns and clears the accumulated dirty rectangle (framebuffer pixels, top-left origin).
    func takeDirtyRect() -> CGRect? {
        defer { dirty = nil }
        return dirty.map { CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX, height: $0.maxY - $0.minY) }
    }

    // MARK: - Snapshot

    /// Copies the current pixels into an immutable `CGImage`. The copy lives in a recycled buffer from a small pool,
    /// so steady-state streaming does not allocate (the pool returns buffers when Core Animation drops the image).
    func makeImage() -> CGImage? {
        let buffer = pool.obtain()
        buffer.copyMemory(from: pixels, byteCount: byteCount)
        let box = ImageBufferPool.Lease(pointer: buffer, pool: pool)
        let info = Unmanaged.passRetained(box).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: buffer, size: byteCount, releaseData: { info, _, _ in
            guard let info else { return }
            Unmanaged<ImageBufferPool.Lease>.fromOpaque(info).takeRetainedValue().giveBack()
        }) else {
            Unmanaged<ImageBufferPool.Lease>.fromOpaque(info).release()
            pool.recycle(buffer)
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: Self.colorSpace, bitmapInfo: Self.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Recycles snapshot buffers of one size. Buffers come back from Core Graphics' release callback (any thread).
final class ImageBufferPool: Sendable {
    /// One outstanding buffer; returns it to the pool (or frees it if the pool is gone after a resize).
    final class Lease: @unchecked Sendable {
        // Immutable after init; `pool` is weak so a resized framebuffer's old pool can go away.
        let pointer: UnsafeMutableRawPointer
        weak var pool: ImageBufferPool?

        init(pointer: UnsafeMutableRawPointer, pool: ImageBufferPool) {
            self.pointer = pointer
            self.pool = pool
        }

        func giveBack() {
            if let pool { pool.recycle(pointer) } else { pointer.deallocate() }
        }
    }

    private struct Free: @unchecked Sendable { var buffers: [UnsafeMutableRawPointer] = [] }
    let byteCount: Int
    private let free = Mutex(Free())
    private static let maxFree = 3

    init(byteCount: Int) { self.byteCount = max(byteCount, 4) }

    deinit {
        free.withLock { f in f.buffers.forEach { $0.deallocate() } }
    }

    func obtain() -> UnsafeMutableRawPointer {
        if let p = free.withLock({ $0.buffers.popLast() }) { return p }
        return UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    }

    func recycle(_ p: UnsafeMutableRawPointer) {
        let kept = free.withLock { f -> Bool in
            guard f.buffers.count < Self.maxFree else { return false }
            f.buffers.append(p)
            return true
        }
        if !kept { p.deallocate() }
    }
}
