import Foundation
import Testing
@testable import NEBULADesktop

/// Opt-in: the real RFB client + real WebSocket transport against a running NEBULA (E2E server or the live one).
/// NEBULA_LIVE_WS_URL = a ready wss/ws URL with session_token + single-use token. Skipped when unset.
@Suite("Live server probe")
struct LiveServerProbeTests {
    @Test func connectsAndDecodesFrames() async throws {
        guard let s = ProcessInfo.processInfo.environment["NEBULA_LIVE_WS_URL"], let url = URL(string: s) else { return }
        let transport = WebSocketRFBTransport(url: url)
        let mailbox = FrameMailbox()
        let client = RFBClient(transport: transport, mailbox: mailbox)
        let runner = Task { () -> String in
            do { try await client.run(); return "ended" } catch { return "error: \(error)" }
        }
        let events = client.events
        let watcher = Task { () -> (Bool, Bool) in
            var connected = false
            for await e in events {
                print("PROBE event \(e)")
                if case .connected = e { connected = true }
                if case .firstUpdate = e { return (connected, true) }
            }
            return (connected, false)
        }
        let timer = Task { try? await Task.sleep(for: .seconds(15)); watcher.cancel() }
        let (gotConnected, gotFrame) = await watcher.value
        timer.cancel()
        runner.cancel()
        let end = await runner.value
        print("PROBE result connected=\(gotConnected) frame=\(gotFrame) end=\(end)")
        #expect(gotConnected && gotFrame, "\(end)")
    }
}
