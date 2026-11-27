import Foundation
import Testing
@testable import NEBULACore
@testable import NEBULANetwork

/// Serves a canned text/event-stream body (split into odd chunks) to the real URLSession stack.
final class SSEStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let data = Data(Self.body.utf8)
        var i = 0
        while i < data.count {  // deliberately awkward chunk boundaries (inside lines and between \n\n)
            let n = min(7, data.count - i)
            client?.urlProtocol(self, didLoad: data.subdata(in: i..<(i + n)))
            i += n
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct FixedToken: SessionTokenProvider {
    func sessionToken(forceRefresh: Bool) async throws -> String { "tok" }
}

@Suite("Event stream over URLSession", .serialized)
struct EventStreamTests {
    @Test func deliversEventsSeparatedByBlankLinesAndNeverTwice() async throws {
        let ev = { (seq: Int?, type: String) -> String in
            let s = seq.map(String.init) ?? "null"
            return (seq.map { "id: \($0)\n" } ?? "") + "event: \(type)\n" +
                "data: {\"id\":\"e\",\"sequence\":\(s),\"type\":\"\(type)\",\"payload\":{}}\n\n"
        }
        SSEStubProtocol.body = "retry: 3000\n\n: keepalive\n\n" + ev(5, "task.started") +
            ev(nil, "task.output.delta") + ev(5, "task.started") + ev(6, "task.completed")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SSEStubProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://nebula.test")!, tokens: FixedToken(),
                            session: URLSession(configuration: cfg))
        let stream = EventStream(client: api, since: 4)
        let events = await stream.events()
        await stream.start()
        var got: [String] = []
        for await e in events {
            got.append("\(e.sequence.map(String.init) ?? "-"):\(e.type)")
            if got.count == 3 { break }
        }
        await stream.stop()
        #expect(got == ["5:task.started", "-:task.output.delta", "6:task.completed"])  // duplicate 5 dropped
        let req = try #require(SSEStubProtocol.requests.first)
        #expect(req.url?.query == "since=4")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }
}
