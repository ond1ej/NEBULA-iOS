import Foundation

/// The receive buffer of the RFB stream. WebSocket frames split RFB messages arbitrarily, so incoming chunks are
/// appended here and parsed once enough bytes are present. Every read is bounds-checked and throws on underflow.
struct ByteBuffer {
    private var storage: [UInt8] = []
    private var head = 0

    /// Unread bytes.
    var count: Int { storage.count - head }

    mutating func append(_ data: Data) {
        // Compact lazily (amortised O(1)): only once the consumed prefix dominates the storage.
        if head > 0, head >= 1 << 16 || head * 2 >= storage.count {
            storage.removeSubrange(0..<head)
            head = 0
        }
        storage.append(contentsOf: data)
    }

    private func check(_ n: Int, _ what: @autoclosure () -> String) throws {
        guard n >= 0, count >= n else { throw RFBError.truncated(what()) }
    }

    mutating func readU8() throws -> UInt8 {
        try check(1, "u8")
        defer { head += 1 }
        return storage[head]
    }

    mutating func readU16() throws -> UInt16 {
        try check(2, "u16")
        defer { head += 2 }
        return UInt16(storage[head]) << 8 | UInt16(storage[head + 1])
    }

    mutating func readU32() throws -> UInt32 {
        try check(4, "u32")
        defer { head += 4 }
        return UInt32(storage[head]) << 24 | UInt32(storage[head + 1]) << 16
            | UInt32(storage[head + 2]) << 8 | UInt32(storage[head + 3])
    }

    mutating func readS32() throws -> Int32 {
        Int32(bitPattern: try readU32())
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        try check(n, "\(n) bytes")
        defer { head += n }
        return Array(storage[head..<head + n])
    }

    mutating func skip(_ n: Int) throws {
        try check(n, "skip \(n)")
        head += n
    }

    /// Hands the next `n` bytes to `body` without copying, then consumes them.
    mutating func withBytes<R>(_ n: Int, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try check(n, "\(n) bytes")
        let start = head
        head += n
        return try storage.withUnsafeBytes { raw in
            try body(UnsafeRawBufferPointer(rebasing: raw[start..<start + n]))
        }
    }
}

/// A bounds-checked forward reader over a contiguous byte region (inflated Tight / ZRLE data).
struct ByteCursor {
    let bytes: UnsafeRawBufferPointer
    private(set) var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    @inline(__always)
    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw RFBError.truncated("compressed payload") }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Takes the next `n` bytes as a sub-region.
    mutating func take(_ n: Int) throws -> UnsafeRawBufferPointer {
        guard n >= 0, remaining >= n else { throw RFBError.truncated("compressed payload (\(n) bytes)") }
        defer { offset += n }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + n])
    }
}
