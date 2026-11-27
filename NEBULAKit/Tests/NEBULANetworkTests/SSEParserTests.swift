import Foundation
import Testing
@testable import NEBULACore
@testable import NEBULANetwork

@Suite("Server-sent events")
struct SSEParserTests {
    func parse(_ text: String) -> ([SSEParser.Event], Int?) {
        var p = SSEParser()
        var out: [SSEParser.Event] = []
        for line in text.components(separatedBy: "\n") { if let e = p.feed(line: line) { out.append(e) } }
        return (out, p.retryMs)
    }

    @Test func parsesNebulaStream() {
        let (evs, retry) = parse("retry: 3000\n\n: keepalive\n\nid: 41\nevent: task.started\ndata: {\"a\":1}\n\n" +
                                 "event: task.output.delta\ndata: {\"b\":2}\n\n")
        #expect(retry == 3000)
        #expect(evs == [.init(id: "41", event: "task.started", data: "{\"a\":1}"),
                        .init(id: nil, event: "task.output.delta", data: "{\"b\":2}")])
    }

    @Test func multiLineDataAndNoSpace() {
        let (evs, _) = parse("data:first\ndata: second\n\n")
        #expect(evs.first?.data == "first\nsecond" && evs.first?.event == "message")
    }

    @Test func decodesServerEvents() throws {
        let json = #"{"id":"e1","sequence":7,"type":"task.stage","agent_id":"a","task_id":"t","timestamp":1.5,"payload":{"stage":"tool","elapsed_ms":1200}}"#
        let ev = try NJSON.decoder().decode(ServerEvent.self, from: Data(json.utf8))
        #expect(ev.sequence == 7 && ev.payload?["stage"]?.string == "tool" && ev.payload?["elapsed_ms"]?.int == 1200)
        let live = #"{"id":null,"sequence":null,"type":"task.output.delta","agent_id":"a","task_id":"t","timestamp":2,"payload":{"turn":0,"offset":0,"delta":"Ahoj","done":false}}"#
        let d = try NJSON.decoder().decode(ServerEvent.self, from: Data(live.utf8))
        #expect(d.sequence == nil && d.payload?["delta"]?.string == "Ahoj")
    }

    @Test func apiErrorsKeepServerCodes() {
        let body = #"{"error":{"code":"stepup_required","message":"confirm it's you","details":{"methods":["device"]}},"request_id":"r"}"#
        let e = APIClient.error(from: Data(body.utf8), status: 403)
        #expect(e.needsStepUp && e.details?["methods"]?.array?.first?.string == "device")
        #expect(APIClient.error(from: Data(), status: 503).code == "http_503")
    }
}
