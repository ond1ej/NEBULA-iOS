import Foundation
@testable import NEBULADesktop
import Testing

@Suite("RFB handshake")
struct HandshakeTests {
    @Test("RFB 3.8: version, security None + SecurityResult, shared ClientInit, setup messages")
    func handshake38() async throws {
        let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
        let client = RFBClient(transport: clientEnd)
        let server = FakeRFBServer(transport: serverEnd)
        let events = Task { () -> RFBServerInfo? in
            for await e in client.events { if case .connected(let info) = e { return info } }
            return nil
        }
        let run = Task { try await client.run() }
        try await server.handshake(version: .v38, width: 1280, height: 800, name: "agent-desktop")
        #expect(await server.clientVersion == "RFB 003.008\n")
        #expect(await server.sharedFlag == 1)

        let pixelFormat = try await server.readMessage()
        #expect(pixelFormat == .setPixelFormat([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        let encodings = try await server.readMessage()
        #expect(encodings == .setEncodings(expectedEncodings(quality: 7)))
        let request = try await server.readMessage()
        #expect(request == .updateRequest(incremental: false, x: 0, y: 0, width: 1280, height: 800))

        let info = await events.value
        #expect(info == RFBServerInfo(protocolVersion: .v3_8, name: "agent-desktop", width: 1280, height: 800))
        #expect(await client.desktopSize?.width == 1280)
        client.close()
        await #expect(throws: (any Error).self) { try await run.value }
    }

    @Test("RFB 3.3 server: the client answers 3.3 and reads the U32 security type")
    func handshake33() async throws {
        let h = try await Harness.start(version: .v33, width: 320, height: 200)
        #expect(await h.server.clientVersion == "RFB 003.003\n")
        #expect(await h.client.desktopSize?.height == 200)
        try await h.apply([Wire.tightFill(0, 0, 320, 200, 0x112233)])
        #expect(await h.client.pixel(x: 319, y: 199) == 0xFF11_2233)
        h.stop()
    }

    @Test("RFB 3.7 server: security list without SecurityResult")
    func handshake37() async throws {
        let h = try await Harness.start(version: .v37, width: 100, height: 50)
        #expect(await h.server.clientVersion == "RFB 003.007\n")
        try await h.apply([Wire.tightFill(0, 0, 100, 50, 0xABCDEF)])
        #expect(await h.client.pixel(x: 50, y: 25) == 0xFFAB_CDEF)
        h.stop()
    }

    @Test("Newer servers (3.889) negotiate 3.8")
    func newerVersion() throws {
        let v = try RFBVersion.parse(Array("RFB 003.889\n".utf8)).negotiated()
        #expect(v == .v3_8)
        #expect(String(decoding: v.handshake, as: UTF8.self) == "RFB 003.008\n")
        #expect(try RFBVersion.parse(Array("RFB 003.005\n".utf8)).negotiated() == .v3_3)
    }

    @Test("Garbage version line is rejected")
    func badVersion() async throws {
        let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
        let client = RFBClient(transport: clientEnd)
        let run = Task { try await client.run() }
        try await serverEnd.send(Data("HTTP/1.1 403\n".utf8))
        await #expect(throws: RFBError.self) { try await run.value }
        #expect(throws: RFBError.self) { try RFBVersion.parse(Array("RFB 002.000\n".utf8)).negotiated() }
    }

    @Test("Server refusal (0 security types) surfaces the reason")
    func securityFailure() async throws {
        let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
        let client = RFBClient(transport: clientEnd)
        let run = Task { try await client.run() }
        let server = FakeRFBServer(transport: serverEnd)
        try await server.send(Array("RFB 003.008\n".utf8))
        _ = try await server.read(12)
        try await server.send([0] + Wire.u32(9) + Array("too many!".utf8))
        do {
            try await run.value
            Issue.record("expected failure")
        } catch let error as RFBError {
            #expect(error == .securityFailure("too many!"))
        }
    }

    @Test("VNC password auth only (no None) is refused")
    func unsupportedSecurity() async throws {
        let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
        let client = RFBClient(transport: clientEnd)
        let run = Task { try await client.run() }
        let server = FakeRFBServer(transport: serverEnd)
        try await server.send(Array("RFB 003.008\n".utf8))
        _ = try await server.read(12)
        try await server.send([1, 2])
        do {
            try await run.value
            Issue.record("expected failure")
        } catch let error as RFBError {
            #expect(error == .unsupportedSecurityTypes([2]))
        }
    }

    @Test("Oversized or empty desktops are rejected at ServerInit")
    func oversizedDesktop() async throws {
        for (w, h) in [(9000, 10), (0, 100), (8192, 8192)] {
            let (clientEnd, serverEnd) = InMemoryRFBTransport.pair()
            let client = RFBClient(transport: clientEnd)
            let run = Task { try await client.run() }
            let server = FakeRFBServer(transport: serverEnd)
            try await server.handshake(width: w, height: h)
            do {
                try await run.value
                Issue.record("expected failure for \(w)x\(h)")
            } catch let error as RFBError {
                #expect(error == .invalidFramebufferSize(width: w, height: h))
            }
        }
    }
}
