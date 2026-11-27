import Foundation
import NEBULACore

/// An error answered by NEBULA (`{"error": {"code", "message", "details"}}`) or a transport failure.
public struct APIError: Error, Sendable, Equatable, LocalizedError {
    public var status: Int
    public var code: String
    public var message: String
    public var details: JSONValue?

    public init(status: Int, code: String, message: String, details: JSONValue? = nil) {
        self.status = status; self.code = code; self.message = message; self.details = details
    }

    public var errorDescription: String? { message }

    /// The device / network could not reach NEBULA at all (offline, DNS, TLS, timeout).
    public var isOffline: Bool { status == 0 }
    public var needsStepUp: Bool { code == "stepup_required" }
    public var vaultLocked: Bool { code == "vault_locked" }
    public var retryAfter: Double? { details?["retry_after"]?.double }

    static func transport(_ error: any Error) -> APIError {
        let ns = error as NSError
        let text: String
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            text = String(localized: "No internet connection")
        case NSURLErrorTimedOut: text = String(localized: "NEBULA is not responding (timed out)")
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            text = String(localized: "The Mac mini running NEBULA is unreachable")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasUnknownRoot:
            text = String(localized: "Could not verify the secure connection")
        case NSURLErrorCancelled: text = String(localized: "Cancelled")
        default: text = String(localized: "The connection to NEBULA failed")
        }
        return APIError(status: 0, code: ns.code == NSURLErrorCancelled ? "cancelled" : "offline", message: text)
    }
}

/// Supplies the bearer token of the app's device session (NEBULAAuth signs a fresh one in when needed).
public protocol SessionTokenProvider: Sendable {
    func sessionToken(forceRefresh: Bool) async throws -> String
}

private struct Envelope<T: Decodable>: Decodable { let data: T }
private struct ErrorEnvelope: Decodable {
    struct Body: Decodable { let code: String; let message: String?; let details: JSONValue? }
    let error: Body
}

public struct Empty: Codable, Sendable { public init() {} }

/// Typed client of NEBULA's API through the owner's HTTPS gateway (the only address the apps use, at home and away).
/// Thread-safe (immutable + URLSession); one instance per paired server.
public final class APIClient: Sendable {
    public let baseURL: URL
    let session: URLSession
    let tokens: (any SessionTokenProvider)?
    let decoder = NJSON.decoder()

    public init(baseURL: URL, tokens: (any SessionTokenProvider)?, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session ?? APIClient.makeSession()
    }

    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil  // bearer tokens only: never cookies
        c.httpShouldSetCookies = false
        c.urlCache = nil  // responses may contain personal data: nothing cached on disk
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "NEBULA-Apple/1.0"]
        return URLSession(configuration: c)
    }

    // MARK: requests

    public func get<T: Decodable & Sendable>(_ path: String, query: [String: String?] = [:],
                                              as: T.Type = T.self) async throws -> T {
        try await send("GET", path, query: query, body: Optional<Empty>.none)
    }

    public func post<T: Decodable & Sendable, B: Encodable & Sendable>(_ path: String, body: B,
                                                                       idempotencyKey: String? = nil,
                                                                       as: T.Type = T.self) async throws -> T {
        try await send("POST", path, body: body, idempotencyKey: idempotencyKey)
    }

    public func post<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try await send("POST", path, body: Optional<Empty>.none)
    }

    public func put<T: Decodable & Sendable, B: Encodable & Sendable>(_ path: String, body: B,
                                                                      as: T.Type = T.self) async throws -> T {
        try await send("PUT", path, body: body)
    }

    public func patch<T: Decodable & Sendable, B: Encodable & Sendable>(_ path: String, body: B,
                                                                        as: T.Type = T.self) async throws -> T {
        try await send("PATCH", path, body: body)
    }

    public func delete<T: Decodable & Sendable>(_ path: String, query: [String: String?] = [:],
                                                 as: T.Type = T.self) async throws -> T {
        try await send("DELETE", path, query: query, body: Optional<Empty>.none)
    }

    /// Calls a public gateway endpoint (/api/app/…: pairing, device sign-in) without a session.
    public func publicPost<T: Decodable & Sendable, B: Encodable & Sendable>(_ path: String, body: B,
                                                                             as: T.Type = T.self) async throws -> T {
        var req = URLRequest(url: url(path, query: [:]))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try NJSON.encoder().encode(body)
        return try await perform(req)
    }

    public func publicGet<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try await perform(URLRequest(url: url(path, query: [:])))
    }

    func url(_ path: String, query: [String: String?]) -> URL {
        let full = path.hasPrefix("/api/") ? path : "/api/v1" + path
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = full.split(separator: "?").first.map(String.init) ?? full
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        comps.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        return comps.url!
    }

    func send<T: Decodable & Sendable, B: Encodable & Sendable>(_ method: String, _ path: String,
                                                                query: [String: String?] = [:], body: B?,
                                                                idempotencyKey: String? = nil) async throws -> T {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try NJSON.encoder().encode(body)
        }
        if let idempotencyKey { req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        return try await authorized(req)
    }

    /// Adds the session token; on 401 signs in again once (the device key needs no user interaction).
    public func authorized<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        guard let tokens else { return try await perform(request) }
        var req = request
        req.setValue("Bearer \(try await tokens.sessionToken(forceRefresh: false))", forHTTPHeaderField: "Authorization")
        do {
            return try await perform(req)
        } catch let e as APIError where e.status == 401 && e.code == "unauthenticated" {
            req.setValue("Bearer \(try await tokens.sessionToken(forceRefresh: true))",
                         forHTTPHeaderField: "Authorization")
            return try await perform(req)
        }
    }

    /// The raw bytes of an authorized GET (attachments, artifacts, screenshots).
    public func data(_ path: String, query: [String: String?] = [:]) async throws -> (Data, String?) {
        guard let tokens else { throw APIError(status: 401, code: "unauthenticated", message: "not paired") }
        var req = URLRequest(url: url(path, query: query))
        req.setValue("Bearer \(try await tokens.sessionToken(forceRefresh: false))", forHTTPHeaderField: "Authorization")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, resp) = try await raw(req)
        return (data, resp.value(forHTTPHeaderField: "Content-Type"))
    }

    /// multipart/form-data upload (attachments, voice notes).
    public func upload<T: Decodable & Sendable>(_ path: String, fileName: String, mime: String, data: Data,
                                                fields: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        let boundary = "nebula-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        body.append(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n" +
                     "Content-Type: \(mime)\r\n\r\n").data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url(path, query: [:]))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await authorized(req)
    }

    func raw(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError(status: 0, code: "offline", message: String(localized: "Invalid server response"))
        }
        if !(200..<300).contains(http.statusCode) {
            throw Self.error(from: data, status: http.statusCode)
        }
        return (data, http)
    }

    func perform<T: Decodable & Sendable>(_ req: URLRequest) async throws -> T {
        let (data, _) = try await raw(req)
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try decoder.decode(Envelope<T>.self, from: data).data
        } catch {
            NLog.net.error("decode failed for \(req.url?.path ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            throw APIError(status: 200, code: "bad_response",
                           message: String(localized: "The server response has an unexpected shape"))
        }
    }

    static func error(from data: Data, status: Int) -> APIError {
        if let e = try? NJSON.decoder().decode(ErrorEnvelope.self, from: data) {
            return APIError(status: status, code: e.error.code,
                            message: e.error.message ?? String(localized: "The request failed"),
                            details: e.error.details)
        }
        let text: String
        switch status {
        case 401: text = String(localized: "Sign-in timed out")
        case 403: text = String(localized: "You do not have permission for this action")
        case 404: text = String(localized: "Not found")
        case 413: text = String(localized: "The file is too large")
        case 429: text = String(localized: "Too many requests, try again in a moment")
        case 502, 503, 504: text = String(localized: "NEBULA is temporarily unavailable")
        default: text = String(localized: "The request failed (\(status))")
        }
        return APIError(status: status, code: "http_\(status)", message: text)
    }
}
