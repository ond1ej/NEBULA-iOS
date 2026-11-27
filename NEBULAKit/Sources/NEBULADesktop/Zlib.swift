import CZlib
import Foundation

/// A growable scratch buffer reused across rectangles (capacity only ever grows up to the decoder's limit), so the
/// decoders do not allocate per frame.
final class ScratchBuffer {
    private(set) var base: UnsafeMutableRawPointer
    private(set) var capacity: Int

    init(capacity: Int = 64 * 1024) {
        self.capacity = max(capacity, 16)
        base = .allocate(byteCount: self.capacity, alignment: 16)
    }

    deinit { base.deallocate() }

    /// Ensures `capacity >= needed`, keeping the first `preserving` bytes.
    func reserve(_ needed: Int, preserving: Int = 0) {
        guard needed > capacity else { return }
        var newCapacity = capacity
        while newCapacity < needed { newCapacity = newCapacity > Int.max / 2 ? needed : newCapacity * 2 }
        let fresh = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
        if preserving > 0 { fresh.copyMemory(from: base, byteCount: min(preserving, capacity)) }
        base.deallocate()
        base = fresh
        capacity = newCapacity
    }

    func bytes(_ count: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: min(max(count, 0), capacity))
    }
}

/// A persistent zlib inflate stream. Tight keeps four of them and ZRLE one for the whole connection; the server
/// flushes each rectangle with Z_SYNC_FLUSH, so all of a rectangle's output is available once its input is consumed.
///
/// The `z_stream` lives at a stable heap address: zlib keeps a back-pointer to it and rejects a moved stream.
final class InflateStream {
    private let stream: UnsafeMutablePointer<z_stream>
    private var isInitialized = false

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if isInitialized { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Resets the dictionary/state (Tight's per-stream reset bits).
    func reset() {
        guard isInitialized else { return }
        if inflateReset(stream) != Z_OK {
            inflateEnd(stream)
            isInitialized = false
        }
    }

    private func prepare() throws {
        guard !isInitialized else { return }
        stream.pointee = z_stream()
        let status = inflateInit_(stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw RFBError.decompressionFailed("inflateInit \(status)") }
        isInitialized = true
    }

    private func detachBuffers() {
        stream.pointee.next_in = nil
        stream.pointee.avail_in = 0
        stream.pointee.next_out = nil
        stream.pointee.avail_out = 0
    }

    /// Inflates `input` into exactly `output.count` bytes. Trailing input that inflates to nothing (an empty
    /// sync-flush block) is consumed; any further decompressed byte is a protocol error.
    func inflate(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws {
        guard output.count > 0 else { return }
        guard let inBase = input.baseAddress, input.count > 0, let outBase = output.baseAddress else {
            throw RFBError.truncated("empty zlib payload")
        }
        guard input.count <= Int(UInt32.max), output.count <= Int(UInt32.max) else {
            throw RFBError.messageTooLarge(max(input.count, output.count))
        }
        try prepare()
        defer { detachBuffers() }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: inBase.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = uInt(input.count)
        stream.pointee.next_out = outBase.assumingMemoryBound(to: Bytef.self)
        stream.pointee.avail_out = uInt(output.count)
        while stream.pointee.avail_out > 0 {
            let status = CZlib.inflate(stream, Z_SYNC_FLUSH)
            if status == Z_STREAM_END || status == Z_BUF_ERROR { break }
            guard status == Z_OK else { throw RFBError.decompressionFailed("inflate \(status)") }
        }
        guard stream.pointee.avail_out == 0 else {
            throw RFBError.decompressionFailed("short output (\(stream.pointee.avail_out) bytes missing)")
        }
        // Drain the rest of this rectangle's input (normally the 4-byte empty sync block).
        var sink: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        try withUnsafeMutableBytes(of: &sink) { scratch in
            while stream.pointee.avail_in > 0 {
                stream.pointee.next_out = scratch.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.pointee.avail_out = uInt(scratch.count)
                let status = CZlib.inflate(stream, Z_SYNC_FLUSH)
                if stream.pointee.avail_out != uInt(scratch.count) {
                    throw RFBError.decompressionFailed("more data than the rectangle needs")
                }
                if status == Z_STREAM_END || status == Z_BUF_ERROR { break }
                guard status == Z_OK else { throw RFBError.decompressionFailed("inflate \(status)") }
            }
        }
    }

    /// Inflates all of `input` into `scratch` (grown as needed, never beyond `limit` bytes). Returns the output size.
    func inflateAll(_ input: UnsafeRawBufferPointer, into scratch: ScratchBuffer, limit: Int) throws -> Int {
        guard let inBase = input.baseAddress, input.count > 0 else { return 0 }
        guard input.count <= Int(UInt32.max) else { throw RFBError.messageTooLarge(input.count) }
        try prepare()
        defer { detachBuffers() }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: inBase.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = uInt(input.count)
        var produced = 0
        while true {
            if produced >= scratch.capacity {
                guard scratch.capacity < limit else { throw RFBError.messageTooLarge(produced) }
                scratch.reserve(min(limit, scratch.capacity * 2), preserving: produced)
            }
            let space = min(scratch.capacity, limit) - produced
            guard space > 0 else { throw RFBError.messageTooLarge(produced) }
            stream.pointee.next_out = (scratch.base + produced).assumingMemoryBound(to: Bytef.self)
            stream.pointee.avail_out = uInt(min(space, Int(UInt32.max)))
            let before = Int(stream.pointee.avail_out)
            let status = CZlib.inflate(stream, Z_SYNC_FLUSH)
            produced += before - Int(stream.pointee.avail_out)
            switch status {
            case Z_OK:
                if stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0 { return produced }
            case Z_BUF_ERROR:
                if stream.pointee.avail_in == 0 { return produced }
                if stream.pointee.avail_out > 0 { throw RFBError.decompressionFailed("inflate made no progress") }
            case Z_STREAM_END:
                reset()
                return produced
            default:
                throw RFBError.decompressionFailed("inflate \(status)")
            }
        }
    }
}
