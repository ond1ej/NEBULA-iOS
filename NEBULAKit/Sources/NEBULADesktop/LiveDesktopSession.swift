import CoreGraphics
import Foundation
import NEBULADesignSystem
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Why a live session ended.
public enum LiveEndReason: Equatable, Sendable {
    /// The owner disconnected.
    case userDisconnected
    /// The view went away (`leave()`).
    case leftScreen
    /// The app went to the background (resumes automatically when it becomes active again).
    case backgrounded
    /// Reconnecting failed `maxReconnectAttempts` times.
    case connectionLost(String)
    /// A non-retryable error (desktop not running, access refused, unsupported server).
    case failed(String)
}

/// The session's state machine.
public enum LiveDesktopState: Equatable, Sendable {
    case idle
    case connecting
    /// Connected, view-only.
    case viewing
    /// Connected and holding the control lease (input enabled).
    case controlling
    /// The connection broke; reconnecting with a fresh connect (view-only afterwards).
    case reconnecting(attempt: Int)
    case ended(LiveEndReason)

    public var isConnected: Bool { self == .viewing || self == .controlling }
}

/// A transient notice about control (shown as a banner, cleared after a few seconds).
public enum LiveControlNotice: Equatable, Sendable {
    case leaseConflict
    case agentBusy
    case expired
    case failed(String)

    public var message: String {
        switch self {
        case .leaseConflict: String(localized: "Someone else is controlling it right now.")
        case .agentBusy: String(localized: "The agent did not reach a safe point in time. Try taking control again.")
        case .expired: String(localized: "Control has ended. Take control again to intervene further.")
        case .failed(let m): m
        }
    }
}

/// Once-per-second stream metrics.
public struct LiveDesktopMetrics: Equatable, Sendable {
    /// Frames presented by the renderer per second.
    public var framesPerSecond: Double = 0
    /// FramebufferUpdates decoded per second.
    public var updatesPerSecond: Double = 0
    /// Received bytes per second.
    public var bytesPerSecond: Double = 0
    /// Bytes received during the whole session (across reconnects).
    public var totalBytes: Int = 0
    public init() {}
}

/// One live view of an agent's desktop: connection, reconnects, control lease, input and metrics.
///
/// Safety rules (enforced here, independent of the UI):
/// * Input is accepted only while the control lease is held (`inputEnabled`).
/// * On any connection loss or error, input is disabled immediately, the renew timer stops and a best-effort
///   `release` + `disconnect` is sent, so remote control is never left held. Reconnects use a brand-new connect
///   (live tokens are single-use) and stay view-only: control must be taken again explicitly.
/// * Leaving the screen or the app going to the background releases control and disconnects.
@MainActor
@Observable
public final class LiveDesktopSession {
    public struct Configuration: Sendable {
        /// Tight JPEG quality 0…9.
        public var imageQuality: Int
        public var compressionLevel: Int
        /// Use the Cursor pseudo-encoding (local cursor; off by default so viewers see the agent's pointer).
        public var requestCursorShape: Bool
        /// Lease renewal period while in control (the server lease is longer; typically 60–300 s).
        public var renewInterval: Duration
        public var maxReconnectAttempts: Int
        public var reconnectBaseDelay: Duration
        public var reconnectMaxDelay: Duration
        /// Timeout of best-effort calls (release / disconnect / renew / acquire).
        public var requestTimeout: Duration
        public var maximumDimension: Int
        public var maximumPixels: Int

        public init(imageQuality: Int = 7, compressionLevel: Int = 6, requestCursorShape: Bool = false,
                    renewInterval: Duration = .seconds(20), maxReconnectAttempts: Int = 5,
                    reconnectBaseDelay: Duration = .milliseconds(500), reconnectMaxDelay: Duration = .seconds(8),
                    requestTimeout: Duration = .seconds(8), maximumDimension: Int = 8192,
                    maximumPixels: Int = 16_777_216) {
            self.imageQuality = min(max(imageQuality, 0), 9)
            self.compressionLevel = min(max(compressionLevel, 0), 9)
            self.requestCursorShape = requestCursorShape
            self.renewInterval = renewInterval
            self.maxReconnectAttempts = max(maxReconnectAttempts, 0)
            self.reconnectBaseDelay = reconnectBaseDelay
            self.reconnectMaxDelay = reconnectMaxDelay
            self.requestTimeout = requestTimeout
            self.maximumDimension = maximumDimension
            self.maximumPixels = maximumPixels
        }
    }

    /// Creates the transport for a connect (default: `WebSocketRFBTransport`).
    public typealias TransportFactory = @Sendable (LiveConnectInfo) throws -> any RFBTransport

    public static let webSocketTransport: TransportFactory = { info in
        WebSocketRFBTransport(url: info.webSocketURL)
    }

    // MARK: Observable state

    public let agentID: String
    public private(set) var state: LiveDesktopState = .idle
    /// Desktop size in pixels (nil before the first connection).
    public private(set) var desktopSize: CGSize?
    public private(set) var desktopName: String?
    public private(set) var metrics = LiveDesktopMetrics()
    /// True only while the control lease is held: the views send input only then (and the client enforces it).
    public private(set) var inputEnabled = false
    public private(set) var isAcquiringControl = false
    public private(set) var isPaused = false
    /// A frame has been shown (the connecting placeholder can go).
    public private(set) var hasFrame = false
    public private(set) var controlNotice: LiveControlNotice?
    public private(set) var imageQuality: Int
    /// The remote cursor shape (only with `requestCursorShape`).
    public private(set) var remoteCursor: RemoteCursor?
    /// The software keyboard is requested (iOS; reset when control ends).
    public var isKeyboardVisible = false
    /// macOS: send system shortcuts (Cmd+Q, Cmd+W…) to the desktop instead of the app while in control.
    public var capturesSystemShortcuts = false

    public var maxReconnectAttempts: Int { configuration.maxReconnectAttempts }

    // MARK: Private

    @MainActor
    private final class Connection {
        let id: Int
        let info: LiveConnectInfo
        let client: RFBClient
        var established = false
        /// True from the start of an acquire until a confirmed release: the clean-up then releases.
        var mayHoldControl = false
        private var cleanupClaimed = false

        init(id: Int, info: LiveConnectInfo, client: RFBClient) {
            self.id = id
            self.info = info
            self.client = client
        }

        func claimCleanup() -> Bool {
            defer { cleanupClaimed = true }
            return !cleanupClaimed
        }
    }

    /// Shared with the renderer views.
    @ObservationIgnored let mailbox = FrameMailbox()
    @ObservationIgnored private let backend: any LiveDesktopBackend
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let makeTransport: TransportFactory
    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var connectionCounter = 0
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var renewTask: Task<Void, Never>?
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pauseSequence: UInt64 = 0
    @ObservationIgnored private var bytesOfEndedConnections = 0

    public init(agentID: String, backend: any LiveDesktopBackend, configuration: Configuration = Configuration(),
                transportFactory: @escaping TransportFactory = LiveDesktopSession.webSocketTransport) {
        self.agentID = agentID
        self.backend = backend
        self.configuration = configuration
        self.makeTransport = transportFactory
        imageQuality = configuration.imageQuality
    }

    // MARK: - Lifecycle

    /// Connects (from `idle` or `ended`); no-op while connecting or connected.
    public func start() {
        switch state {
        case .idle, .ended: break
        default: return
        }
        lifecycleTask?.cancel()
        clearNotice()
        state = .connecting
        startMetrics()
        lifecycleTask = Task { [weak self] in await self?.runLifecycle() }
    }

    /// Reconnects after an error or a disconnect (same as `start()`).
    public func retry() { start() }

    /// Releases control (if held) and ends the session.
    public func disconnect() async { await end(.userDisconnected) }

    /// Call when the desktop screen goes away (view disappears, window closes): releases control and disconnects.
    public func leave() async { await end(.leftScreen) }

    /// Call when the app goes to the background (the view does this on iOS via scenePhase).
    public func suspendForBackground() async {
        #if os(iOS)
        let token = BackgroundTaskToken.begin()
        await end(.backgrounded)
        token.end()
        #else
        await end(.backgrounded)
        #endif
    }

    /// Scene phase handling: background → release + disconnect, inactive → pause, active → resume / reconnect.
    public func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            Task { await suspendForBackground() }
        case .inactive:
            pause()
        case .active:
            resume()
            if case .ended(.backgrounded) = state { start() }
        @unknown default:
            break
        }
    }

    private func runLifecycle() async {
        var attempt = 0
        while !Task.isCancelled {
            let result = await runConnection()
            guard !Task.isCancelled else { return }

            var endReason: LiveEndReason?
            if !Self.isRetryable(result.error) {
                endReason = .failed(Self.describe(result.error))
            } else {
                attempt = result.established ? 1 : attempt + 1
                if attempt > configuration.maxReconnectAttempts {
                    endReason = .connectionLost(Self.describe(result.error))
                }
            }
            if let endReason {
                state = .ended(endReason)
            } else {
                state = .reconnecting(attempt: attempt)
            }
            // Never leave remote control held: release (if it may be held) and disconnect the dead session.
            if let conn = result.connection, conn.claimCleanup() {
                await cleanupRemote(conn, closeStream: false)
            }
            if endReason != nil {
                stopMetrics()
                return
            }
            do { try await Task.sleep(for: backoff(attempt)) } catch { return }
        }
    }

    private struct ConnectionResult {
        var error: any Error
        var established: Bool
        var connection: Connection?
    }

    /// Connects once and runs the stream until it ends.
    private func runConnection() async -> ConnectionResult {
        let info: LiveConnectInfo
        do {
            info = try await backend.connect(agentID: agentID)
        } catch {
            return ConnectionResult(error: error, established: false, connection: nil)
        }
        let transport: any RFBTransport
        do {
            transport = try makeTransport(info)
        } catch {
            let id = info.sessionID
            await bestEffort { [backend] in await backend.disconnect(sessionID: id) }
            return ConnectionResult(error: error, established: false, connection: nil)
        }
        connectionCounter += 1
        let client = RFBClient(transport: transport, configuration: clientConfiguration(), mailbox: mailbox)
        let conn = Connection(id: connectionCounter, info: info, client: client)
        guard !Task.isCancelled else {
            client.close()
            if conn.claimCleanup() { await cleanupRemote(conn, closeStream: true) }
            return ConnectionResult(error: CancellationError(), established: false, connection: nil)
        }
        connection = conn
        let events = Task { [weak self] in
            for await event in client.events { self?.handle(event, on: conn) }
        }
        var failure: any Error = RFBTransportError.closed(code: nil, reason: nil)
        do {
            try await client.run()
        } catch {
            failure = error
        }
        // Stream gone: input off before anything else.
        connectionEnded(conn)
        await events.value
        return ConnectionResult(error: failure, established: conn.established, connection: conn)
    }

    private func clientConfiguration() -> RFBClient.Configuration {
        RFBClient.Configuration(jpegQuality: imageQuality, compressionLevel: configuration.compressionLevel,
                                requestCursorShape: configuration.requestCursorShape,
                                maximumDimension: configuration.maximumDimension,
                                maximumPixels: configuration.maximumPixels, startsPaused: isPaused)
    }

    private func handle(_ event: RFBClientEvent, on conn: Connection) {
        guard connection === conn else { return }
        switch event {
        case .connected(let info):
            conn.established = true
            desktopSize = CGSize(width: info.width, height: info.height)
            desktopName = info.name
            state = .viewing
        case .firstUpdate:
            hasFrame = true
        case .desktopResized(let w, let h):
            desktopSize = CGSize(width: w, height: h)
        case .cursorShape(let cursor):
            remoteCursor = cursor
        case .bell:
            break
        }
    }

    /// The stream of `conn` ended (error or close): disable input locally right away.
    private func connectionEnded(_ conn: Connection) {
        conn.client.input.setEnabled(false)
        bytesOfEndedConnections += conn.client.metrics.bytesReceived
        guard connection === conn else { return }
        disableInputLocally()
        connection = nil
    }

    private func disableInputLocally() {
        renewTask?.cancel()
        renewTask = nil
        connection?.client.input.setEnabled(false)
        inputEnabled = false
        isKeyboardVisible = false
        isAcquiringControl = false
        if state == .controlling { state = .viewing }
    }

    private func end(_ reason: LiveEndReason) async {
        switch state {
        case .ended: return
        case .idle:
            state = .ended(reason)
            return
        default: break
        }
        let conn = connection
        lifecycleTask?.cancel()
        lifecycleTask = nil
        if let conn, inputEnabled {
            // Lift held keys / buttons while input still goes through.
            conn.client.input.releaseAll()
            await waitForInputFlush(conn.client.input)
        }
        disableInputLocally()
        connection = nil
        state = .ended(reason)
        stopMetrics()
        if let conn {
            if conn.claimCleanup() {
                await cleanupRemote(conn, closeStream: true)
            } else {
                conn.client.close()
            }
        }
    }

    /// Release (when control may be held), close the stream, disconnect — each best effort with a timeout.
    private func cleanupRemote(_ conn: Connection, closeStream: Bool) async {
        let backend = self.backend
        let sid = conn.info.sessionID
        if conn.mayHoldControl {
            await bestEffort { _ = try await backend.control(sessionID: sid, action: .release) }
            conn.mayHoldControl = false
        }
        if closeStream { conn.client.close() }
        await bestEffort { await backend.disconnect(sessionID: sid) }
    }

    private func bestEffort(_ operation: @escaping @Sendable () async throws -> Void) async {
        _ = try? await withDeadline(configuration.requestTimeout, operation)
    }

    private func waitForInputFlush(_ input: RFBInputQueue) async {
        for _ in 0..<30 where !input.isIdle {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func backoff(_ attempt: Int) -> Duration {
        let base = configuration.reconnectBaseDelay.timeInterval
        let cap = configuration.reconnectMaxDelay.timeInterval
        let delay = min(base * pow(2, Double(max(attempt - 1, 0))), cap)
        let jitter = delay * Double.random(in: -0.2...0.2)
        return .milliseconds(Int64(max(delay + jitter, 0) * 1000))
    }

    // MARK: - Control

    /// Asks for the exclusive control lease; on success input is enabled and the lease renewed periodically.
    public func takeControl() async {
        guard state == .viewing, let conn = connection, !isAcquiringControl else { return }
        isAcquiringControl = true
        clearNotice()
        conn.mayHoldControl = true
        let backend = self.backend
        let sid = conn.info.sessionID
        let held: Bool
        do {
            held = try await withDeadline(configuration.requestTimeout) {
                try await backend.control(sessionID: sid, action: .acquire)
            }
        } catch {
            isAcquiringControl = false
            if let e = error as? LiveBackendError, [.leaseConflict, .agentBusy, .notViewing].contains(e.kind) {
                conn.mayHoldControl = false // the server refused: we certainly do not hold it
            } else {
                // Unknown outcome (timeout, network): make sure the lease is not left behind.
                await bestEffort { _ = try await backend.control(sessionID: sid, action: .release) }
                conn.mayHoldControl = false
            }
            if connection === conn { showNotice(Self.notice(for: error)) }
            return
        }
        isAcquiringControl = false
        guard connection === conn, state == .viewing else {
            // The connection changed meanwhile (its clean-up releases, mayHoldControl is still set).
            return
        }
        guard held else {
            conn.mayHoldControl = false
            showNotice(.leaseConflict)
            return
        }
        conn.client.input.setEnabled(true)
        inputEnabled = true
        state = .controlling
        startRenewTimer(conn)
        Haptics.selection()
    }

    /// Gives the control lease back (held keys/buttons are lifted first); the session stays connected view-only.
    public func releaseControl() async {
        guard state == .controlling, let conn = connection else { return }
        renewTask?.cancel()
        renewTask = nil
        conn.client.input.releaseAll()
        await waitForInputFlush(conn.client.input)
        conn.client.input.setEnabled(false)
        inputEnabled = false
        isKeyboardVisible = false
        if state == .controlling, connection === conn { state = .viewing }
        Haptics.selection()
        let backend = self.backend
        let sid = conn.info.sessionID
        do {
            _ = try await withDeadline(configuration.requestTimeout) {
                try await backend.control(sessionID: sid, action: .release)
            }
            conn.mayHoldControl = false
        } catch {
            // Still flagged: the disconnect clean-up releases again.
        }
    }

    private func startRenewTimer(_ conn: Connection) {
        renewTask?.cancel()
        let interval = configuration.renewInterval
        renewTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, await self.renewOnce(conn) else { return }
            }
        }
    }

    /// Renews the lease; false when control ended (the timer stops).
    private func renewOnce(_ conn: Connection) async -> Bool {
        guard connection === conn, state == .controlling else { return false }
        let backend = self.backend
        let sid = conn.info.sessionID
        do {
            let held = try await withDeadline(configuration.requestTimeout) {
                try await backend.control(sessionID: sid, action: .renew)
            }
            guard connection === conn, state == .controlling else { return false }
            if held { return true }
            controlLost(conn, notice: .expired)
        } catch {
            guard connection === conn, state == .controlling else { return false }
            controlLost(conn, notice: .expired)
        }
        return false
    }

    /// The lease could not be renewed: stop input now and release best-effort.
    private func controlLost(_ conn: Connection, notice: LiveControlNotice) {
        disableInputLocally()
        showNotice(notice)
        let backend = self.backend
        let sid = conn.info.sessionID
        Task { [weak self] in
            await self?.bestEffort { _ = try await backend.control(sessionID: sid, action: .release) }
            conn.mayHoldControl = false
        }
    }

    // MARK: - Pause / quality

    /// Stops requesting updates (and lets the renderer idle), e.g. while the window is hidden.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        applyPause()
    }

    /// Resumes with a full, non-incremental update.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        applyPause()
    }

    private func applyPause() {
        guard let client = connection?.client else { return }
        pauseSequence += 1
        let sequence = pauseSequence, paused = isPaused
        Task { try? await client.setPaused(paused, sequence: sequence) }
    }

    /// Tight JPEG quality 0…9 (lower = less bandwidth).
    public func setImageQuality(_ quality: Int) {
        let q = min(max(quality, 0), 9)
        guard q != imageQuality else { return }
        imageQuality = q
        guard let client = connection?.client else { return }
        Task { try? await client.setJPEGQuality(q) }
    }

    // MARK: - Input (no-ops unless control is held)

    /// Moves the pointer / sets the held buttons.
    public func pointer(at p: FramebufferPoint, buttons: RFBPointerButtons = []) {
        guard inputEnabled, let input = connection?.client.input else { return }
        input.pointer(x: p.x, y: p.y, buttons: buttons)
    }

    /// Clicks `count` times (double click = 2).
    public func click(at p: FramebufferPoint, button: RFBPointerButtons = .left, count: Int = 1) {
        guard inputEnabled, let input = connection?.client.input else { return }
        let held = input.heldButtons.subtracting(button)
        input.pointer(x: p.x, y: p.y, buttons: held)
        for _ in 0..<max(count, 1) {
            input.pointer(x: p.x, y: p.y, buttons: held.union(button))
            input.pointer(x: p.x, y: p.y, buttons: held)
        }
    }

    /// Scrolls by wheel clicks (`.wheelUp`, `.wheelDown`, `.wheelLeft`, `.wheelRight`).
    public func scroll(at p: FramebufferPoint, direction: RFBPointerButtons, clicks: Int = 1) {
        guard inputEnabled, let input = connection?.client.input else { return }
        let held = input.heldButtons
        let wheel = direction.intersection([.wheelUp, .wheelDown, .wheelLeft, .wheelRight])
        guard !wheel.isEmpty else { return }
        for _ in 0..<min(max(clicks, 1), 50) {
            input.pointer(x: p.x, y: p.y, buttons: held.union(wheel))
            input.pointer(x: p.x, y: p.y, buttons: held)
        }
    }

    /// Presses or releases one key.
    public func key(_ keysym: UInt32, down: Bool) {
        guard inputEnabled, let input = connection?.client.input else { return }
        input.key(keysym, down: down)
    }

    /// Taps a key with modifiers held around it (e.g. Ctrl+C: `tap(0x63, modifiers: [Keysym.controlL])`).
    public func tap(_ keysym: UInt32, modifiers: [UInt32] = []) {
        guard inputEnabled, let input = connection?.client.input else { return }
        for m in modifiers { input.key(m, down: true) }
        input.key(keysym, down: true)
        input.key(keysym, down: false)
        for m in modifiers.reversed() { input.key(m, down: false) }
    }

    /// Types text (each character as its keysym; works with any keyboard layout on the desktop side).
    public func type(_ text: String, modifiers: [UInt32] = []) {
        for k in Keysym.forText(text) { tap(k, modifiers: modifiers) }
    }

    /// Lifts every held key and button (focus lost, window deactivated).
    public func releaseHeldInput() {
        guard inputEnabled else { return }
        connection?.client.input.releaseAll()
    }

    // MARK: - Notices / metrics

    private func showNotice(_ notice: LiveControlNotice) {
        controlNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.controlNotice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        controlNotice = nil
    }

    private func startMetrics() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            var last: (connection: Int, bytes: Int, updates: Int, frames: Int, at: ContinuousClock.Instant)?
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let now = ContinuousClock.now
                let frames = self.mailbox.presentedFrameCount
                guard let conn = self.connection else {
                    last = nil
                    if self.metrics.framesPerSecond != 0 || self.metrics.bytesPerSecond != 0 {
                        var m = self.metrics
                        m.framesPerSecond = 0
                        m.updatesPerSecond = 0
                        m.bytesPerSecond = 0
                        self.metrics = m
                    }
                    continue
                }
                let bytes = conn.client.metrics.bytesReceived
                let updates = conn.client.metrics.framebufferUpdates
                var m = LiveDesktopMetrics()
                m.totalBytes = self.bytesOfEndedConnections + bytes
                if let l = last, l.connection == conn.id {
                    let dt = max(l.at.duration(to: now).timeInterval, 0.001)
                    m.framesPerSecond = (Double(frames - l.frames) / dt * 10).rounded() / 10
                    m.updatesPerSecond = (Double(updates - l.updates) / dt * 10).rounded() / 10
                    m.bytesPerSecond = (Double(bytes - l.bytes) / dt).rounded()
                }
                last = (conn.id, bytes, updates, frames, now)
                if m != self.metrics { self.metrics = m }
            }
        }
    }

    private func stopMetrics() {
        metricsTask?.cancel()
        metricsTask = nil
        metrics.framesPerSecond = 0
        metrics.updatesPerSecond = 0
        metrics.bytesPerSecond = 0
    }

    // MARK: - Errors

    static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case let e as LiveBackendError: return e.isRetryable
        case let e as RFBError:
            switch e {
            case .securityFailure, .unsupportedSecurityTypes, .unsupportedVersion: return false
            default: return true
            }
        default: return true
        }
    }

    static func notice(for error: any Error) -> LiveControlNotice {
        if let e = error as? LiveBackendError {
            switch e.kind {
            case .leaseConflict: return .leaseConflict
            case .agentBusy: return .agentBusy
            default: break
            }
        }
        return .failed(String(localized: "Could not take control. \(describe(error))"))
    }

    /// A short, localized description for the owner (never includes tokens or URLs).
    static func describe(_ error: any Error) -> String {
        switch error {
        case let e as LiveBackendError:
            switch e.kind {
            case .desktopNotRunning: return String(localized: "The agent's desktop is not running. Wake the agent and try again.")
            case .hostEnvironment: return String(localized: "This agent works directly on the Mac and has no Live Desktop.")
            case .unauthorized: return String(localized: "You do not have permission to use the Live Desktop.")
            case .network: return String(localized: "The NEBULA server is not available.")
            case .notViewing, .sessionNotFound: return String(localized: "The live session is no longer active.")
            default: return e.message ?? String(localized: "The server refused the Live Desktop connection.")
            }
        case let e as RFBTransportError:
            if e.isAuthorizationFailure { return String(localized: "The server denied access to the Live Desktop.") }
            if case .timedOut = e { return String(localized: "The desktop connection timed out.") }
            return String(localized: "The desktop connection dropped.")
        case let e as RFBError:
            switch e {
            case .securityFailure(let reason): return String(localized: "The desktop refused the connection: \(reason.prefix(120))")
            case .unsupportedSecurityTypes, .unsupportedVersion: return String(localized: "The desktop uses an unsupported protocol.")
            default: return String(localized: "The desktop sent invalid data.")
            }
        case is DeadlineExceeded:
            return String(localized: "The server did not respond in time.")
        default:
            return String(localized: "Could not connect to the desktop.")
        }
    }
}

#if os(iOS)
/// Keeps the app alive briefly in the background so release + disconnect reach the server.
@MainActor
private final class BackgroundTaskToken {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin() -> BackgroundTaskToken {
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "NEBULA live desktop") { [weak token] in
            token?.end()
        }
        return token
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
