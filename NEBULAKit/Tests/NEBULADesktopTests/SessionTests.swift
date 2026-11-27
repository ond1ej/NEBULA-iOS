import Foundation
@testable import NEBULADesktop
import Testing

@MainActor
@Suite("LiveDesktopSession state machine", .serialized)
struct SessionTests {
    private func makeSession(_ backend: FakeBackend, _ hub: ServerHub, renew: Duration = .seconds(60),
                             attempts: Int = 5) -> LiveDesktopSession {
        LiveDesktopSession(agentID: "agent-1", backend: backend,
                           configuration: .init(renewInterval: renew, maxReconnectAttempts: attempts,
                                                reconnectBaseDelay: .milliseconds(2),
                                                reconnectMaxDelay: .milliseconds(10),
                                                requestTimeout: .seconds(1)),
                           transportFactory: hub.factory)
    }

    @Test("Connect → view-only; input is ignored without control")
    func connectViewOnly() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub)
        #expect(session.state == .idle)
        session.start()
        #expect(session.state == .connecting)
        #expect(await eventuallyMain { session.state == .viewing })
        #expect(session.desktopSize == CGSize(width: 32, height: 24))
        #expect(await eventuallyMain { session.hasFrame })
        #expect(!session.inputEnabled)
        session.pointer(at: FramebufferPoint(x: 1, y: 1), buttons: .left)
        session.type("x")
        try? await Task.sleep(for: .milliseconds(50))
        let server = try #require(hub.server("s1"))
        #expect(await server.inputMessages.isEmpty)
        await session.disconnect()
        #expect(session.state == .ended(.userDisconnected))
        #expect(await backend.calls == ["connect", "disconnect:s1"])
    }

    @Test("Take control → input flows and the lease is renewed; release → view-only again")
    func takeAndReleaseControl() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub, renew: .milliseconds(40))
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        await session.takeControl()
        #expect(session.state == .controlling)
        #expect(session.inputEnabled)
        let server = try #require(hub.server("s1"))
        session.click(at: FramebufferPoint(x: 5, y: 6))
        session.tap(0x63, modifiers: [Keysym.controlL])
        let expected: [ClientMessage] = [
            .pointer(buttons: 0, x: 5, y: 6), .pointer(buttons: 1, x: 5, y: 6), .pointer(buttons: 0, x: 5, y: 6),
            .key(keysym: Keysym.controlL, down: true), .key(keysym: 0x63, down: true),
            .key(keysym: 0x63, down: false), .key(keysym: Keysym.controlL, down: false),
        ]
        #expect(await eventually { await server.inputMessages == expected })
        #expect(await eventually { await backend.count("renew:s1") >= 2 })

        // A held key is lifted before the lease goes back.
        session.key(Keysym.shiftL, down: true)
        await session.releaseControl()
        #expect(session.state == .viewing)
        #expect(!session.inputEnabled)
        #expect(await server.inputMessages.last == .key(keysym: Keysym.shiftL, down: false))
        #expect(await backend.calls.contains("release:s1"))
        let renewals = await backend.count("renew:s1")
        let inputCount = await server.inputMessages.count
        session.type("nope")
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await server.inputMessages.count == inputCount)
        #expect(await backend.count("renew:s1") == renewals) // the renew timer stopped
        await session.disconnect()
    }

    @Test("Connection loss: input off, release + disconnect, new connect, view-only")
    func connectionLoss() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub, renew: .milliseconds(30))
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        await session.takeControl()
        #expect(session.inputEnabled)

        let first = try #require(hub.server("s1"))
        first.transport.close() // network drop
        #expect(await eventuallyMain { !session.inputEnabled })
        #expect(await eventually { await backend.connectCount == 2 })
        #expect(await eventuallyMain { session.state == .viewing })
        #expect(!session.inputEnabled) // control is never restored automatically

        let calls = await backend.calls
        let release = try #require(calls.firstIndex(of: "release:s1"))
        let disconnect = try #require(calls.firstIndex(of: "disconnect:s1"))
        let reconnect = try #require(calls.lastIndex(of: "connect"))
        #expect(release < disconnect && disconnect < reconnect)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await backend.count("renew:s1") == calls.filter { $0 == "renew:s1" }.count)

        // the new connection is view-only: input does not reach it
        let second = try #require(hub.server("s2"))
        session.type("x")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await second.inputMessages.isEmpty)
        await session.disconnect()
        #expect(await backend.calls.last == "disconnect:s2")
    }

    @Test("A failed renewal ends control and releases the lease")
    func renewFailure() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub, renew: .milliseconds(30))
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        await session.takeControl()
        await backend.setRenewResult(false)
        #expect(await eventuallyMain { session.state == .viewing })
        #expect(!session.inputEnabled)
        #expect(session.controlNotice == .expired)
        #expect(await eventually { await backend.calls.contains("release:s1") })
        await session.disconnect()
    }

    @Test("Lease conflict: stays view-only with a notice, nothing to release")
    func leaseConflict() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        await backend.setAcquireError(LiveBackendError(kind: .leaseConflict))
        let session = makeSession(backend, hub)
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        await session.takeControl()
        #expect(session.state == .viewing)
        #expect(!session.inputEnabled)
        #expect(session.controlNotice == .leaseConflict)
        await session.disconnect()
        #expect(await backend.calls == ["connect", "acquire:s1", "disconnect:s1"])
    }

    @Test("Disconnect while in control releases first")
    func disconnectReleases() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub)
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        await session.takeControl()
        await session.leave()
        #expect(session.state == .ended(.leftScreen))
        #expect(!session.inputEnabled)
        #expect(await backend.calls == ["connect", "acquire:s1", "release:s1", "disconnect:s1"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.connectCount == 1) // no reconnect after an intentional end
        // start again from ended
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        #expect(await backend.connectCount == 2)
        await session.disconnect()
    }

    @Test("Background suspends (release + disconnect) and foreground reconnects view-only")
    func backgroundForeground() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub)
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        await session.takeControl()
        await session.suspendForBackground()
        #expect(session.state == .ended(.backgrounded))
        #expect(await backend.calls.contains("release:s1"))
        session.handleScenePhase(.active)
        #expect(await eventuallyMain { session.state == .viewing })
        #expect(!session.inputEnabled)
        await session.disconnect()
    }

    @Test("Gives up after the maximum number of reconnect attempts")
    func maxAttempts() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        await backend.setConnectError(LiveBackendError(kind: .network))
        let session = makeSession(backend, hub, attempts: 2)
        session.start()
        #expect(await eventuallyMain {
            if case .ended(.connectionLost) = session.state { return true }
            return false
        })
        #expect(await backend.connectCount == 3)
    }

    @Test("Non-retryable errors end the session at once")
    func nonRetryable() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        await backend.setConnectError(LiveBackendError(kind: .desktopNotRunning))
        let session = makeSession(backend, hub)
        session.start()
        #expect(await eventuallyMain {
            if case .ended(.failed) = session.state { return true }
            return false
        })
        #expect(await backend.connectCount == 1)
    }

    @Test("Pause stops update requests; resume requests a full update")
    func pauseResume() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub)
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        let server = try #require(hub.server("s1"))
        // initial full request + the incremental one after the first update
        #expect(await eventually { await server.updateRequests.count == 2 })
        session.pause()
        #expect(session.isPaused)
        try? await Task.sleep(for: .milliseconds(30))
        try await server.sendUpdate([Wire.tightFill(0, 0, 4, 4, 0x00FF00)])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await server.updateRequests.count == 2)
        session.resume()
        #expect(await eventually { await server.updateRequests.count == 3 })
        #expect(await server.updateRequests.last == .updateRequest(incremental: false, x: 0, y: 0, width: 32, height: 24))
        await session.disconnect()
    }

    @Test("Image quality is applied to the live connection")
    func quality() async throws {
        let backend = FakeBackend(), hub = ServerHub()
        let session = makeSession(backend, hub)
        session.start()
        #expect(await eventuallyMain { session.state == .viewing })
        session.setImageQuality(2)
        #expect(session.imageQuality == 2)
        let server = try #require(hub.server("s1"))
        #expect(await eventually {
            await server.messages.contains(.setEncodings(expectedEncodings(quality: 2)))
        })
        await session.disconnect()
    }
}
