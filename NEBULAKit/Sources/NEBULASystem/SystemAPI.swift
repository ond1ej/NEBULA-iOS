import Foundation
import NEBULACore
import NEBULANetwork

/// GET /devices — the owner's paired NEBULA apps.
public struct PairedDevices: Decodable, Sendable {
    public var devices: [AppDevice]
    public var gatewayUrl: String?
    public var serverFingerprint: String?
}

/// POST /system/backup.
public struct BackupResult: Decodable, Sendable, Hashable {
    public var path: String
    public var sizeBytes: Double?
    public var note: String?
}

public extension APIClient {
    func pairedDevices() async throws -> PairedDevices { try await get("/devices") }

    func createBackup() async throws -> BackupResult { try await post("/system/backup") }

    /// GET /system/diagnostics — a redacted .tar.gz bundle (system, health, providers, recent events, log tails,
    /// config); a JSON answer from a newer server is accepted too.
    func diagnosticsReport() async throws -> DiagnosticsReport {
        let (data, type) = try await self.data("/system/diagnostics")
        return try await Task.detached(priority: .userInitiated) { try DiagnosticsReport.parse(data, contentType: type) }
            .value
    }
}

// MARK: - Diagnostics

/// The diagnostics bundle, unpacked in memory (never written to disk) and summarised for people.
public struct DiagnosticsReport: Sendable {
    public struct File: Sendable, Identifiable, Hashable {
        public var name: String
        public var bytes: Int
        /// Pretty-printed / truncated text for the raw view.
        public var text: String
        public var id: String { name }
    }

    public struct LogSummary: Sendable, Identifiable, Hashable {
        public var name: String
        public var lines: Int
        public var errors: Int
        public var warnings: Int
        public var lastErrors: [String]
        public var id: String { name }
    }

    public var files: [File] = []
    public var health: JSONValue?
    public var system: JSONValue?
    public var providers: [JSONValue] = []
    public struct EventCount: Sendable, Hashable, Identifiable {
        public var type: String
        public var count: Int
        public var id: String { type }
    }

    public var eventCounts: [EventCount] = []
    public var eventTotal = 0
    public var failedEvents = 0
    public var logs: [LogSummary] = []

    public init() {}

    public static func parse(_ data: Data, contentType: String?) throws -> DiagnosticsReport {
        let bytes = [UInt8](data)
        if bytes.count > 2, bytes[0] == 0x1F, bytes[1] == 0x8B {
            let tar = try Gzip.inflate(bytes)
            return summarize(Tar.files(tar))
        }
        if (contentType ?? "").contains("json") || bytes.first == UInt8(ascii: "{") {
            let v = try JSONDecoder().decode(JSONValue.self, from: data)
            let body = v["data"] ?? v
            var files: [String: Data] = [:]
            if let o = body.object {
                for (k, value) in o { files[k + ".json"] = (try? JSONEncoder().encode(value)) ?? Data() }
            }
            return summarize(files)
        }
        throw DiagnosticsError.unknownFormat
    }

    static func summarize(_ files: [String: Data]) -> DiagnosticsReport {
        var r = DiagnosticsReport()
        func json(_ name: String) -> JSONValue? {
            guard let d = files[name], let v = try? JSONDecoder().decode(JSONValue.self, from: d) else { return nil }
            return v["data"] ?? v
        }
        r.health = json("health.json")
        r.system = json("system.json")
        r.providers = json("providers.json")?.array ?? []
        if let events = json("recent_events.json")?.array {
            r.eventTotal = events.count
            var counts: [String: Int] = [:]
            for e in events {
                let t = e["type"]?.string ?? "?"
                counts[t, default: 0] += 1
                if t.hasSuffix(".failed") || t.contains("error") { r.failedEvents += 1 }
            }
            r.eventCounts = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(8).map { EventCount(type: $0.key, count: $0.value) }
        }
        for (name, d) in files where name.hasPrefix("logs/") {
            let text = String(decoding: d, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            var errors = 0, warnings = 0
            var last: [String] = []
            for l in lines {
                if l.contains("ERROR") || l.contains("Traceback") || l.contains("CRITICAL") {
                    errors += 1
                    last.append(String(l.prefix(300)))
                    if last.count > 3 { last.removeFirst() }
                } else if l.contains("WARNING") {
                    warnings += 1
                }
            }
            r.logs.append(LogSummary(name: String(name.dropFirst(5)), lines: lines.count, errors: errors,
                                     warnings: warnings, lastErrors: last))
        }
        r.logs.sort { $0.name < $1.name }
        r.files = files.keys.sorted().map { name in
            let d = files[name] ?? Data()
            return File(name: name, bytes: d.count, text: rawText(d, json: name.hasSuffix(".json")))
        }
        return r
    }

    /// Readable text of one file: JSON pretty-printed, everything capped so the raw view stays fast.
    static func rawText(_ d: Data, json: Bool, maxChars: Int = 24_000) -> String {
        var text: String
        if json, let obj = try? JSONSerialization.jsonObject(with: d),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys,
                                                                                    .withoutEscapingSlashes]) {
            text = String(decoding: pretty, as: UTF8.self)
        } else {
            text = String(decoding: d, as: UTF8.self)
        }
        if text.count > maxChars {
            // logs: the end is the interesting part
            text = json ? String(text.prefix(maxChars)) + "\n…" : "…\n" + String(text.suffix(maxChars))
        }
        return text
    }
}

extension DiagnosticsReport: Hashable {
    public static func == (l: DiagnosticsReport, r: DiagnosticsReport) -> Bool { l.files == r.files }
    public func hash(into h: inout Hasher) { h.combine(files) }
}

enum DiagnosticsError: LocalizedError {
    case unknownFormat, corrupt, tooLarge
    var errorDescription: String? {
        switch self {
        case .unknownFormat: return String(localized: "The diagnostics have an unknown format.")
        case .corrupt: return String(localized: "Could not unpack the diagnostics.")
        case .tooLarge: return String(localized: "The diagnostics are too large to show in the app.")
        }
    }
}

/// gzip (RFC 1952) → raw DEFLATE via Foundation (Compression's zlib is raw DEFLATE).
enum Gzip {
    static func inflate(_ b: [UInt8]) throws -> Data {
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw DiagnosticsError.corrupt }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= b.count else { throw DiagnosticsError.corrupt }
            i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8)
        }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { throw DiagnosticsError.corrupt }
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        guard isize <= 96 * 1024 * 1024 else { throw DiagnosticsError.tooLarge }
        let raw = Data(b[i..<(n - 8)])
        do {
            return try (raw as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw DiagnosticsError.corrupt
        }
    }
}

/// Minimal ustar reader (regular files only; pax / GNU long-name headers are honoured for the name).
enum Tar {
    static func files(_ data: Data) -> [String: Data] {
        let t = [UInt8](data)
        var out: [String: Data] = [:]
        var off = 0
        var longName: String?
        while off + 512 <= t.count {
            let h = t[off..<(off + 512)]
            if h.allSatisfy({ $0 == 0 }) { break }
            func str(_ a: Int, _ len: Int) -> String {
                String(decoding: t[(off + a)..<(off + a + len)].prefix { $0 != 0 }, as: UTF8.self)
            }
            let sizeText = str(124, 12).trimmingCharacters(in: .whitespaces)
            let size = Int(sizeText, radix: 8) ?? 0
            let type = t[off + 156]
            var name = str(0, 100)
            let prefix = str(345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
            let start = off + 512
            let end = min(start + size, t.count)
            switch type {
            case UInt8(ascii: "0"), 0:
                out[longName ?? name] = Data(t[start..<end])
                longName = nil
            case UInt8(ascii: "L"):
                longName = String(decoding: t[start..<end].prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"):
                let pax = String(decoding: t[start..<end], as: UTF8.self)
                for line in pax.split(separator: "\n") {
                    if let r = line.range(of: " path=") { longName = String(line[r.upperBound...]) }
                }
            default:
                break
            }
            off = start + ((size + 511) / 512) * 512
        }
        return out
    }
}
