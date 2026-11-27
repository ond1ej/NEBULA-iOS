import NEBULADesignSystem
import SwiftUI

/// The live desktop of an agent: canvas, status overlay and (optionally) the toolbar.
///
/// Starts the session when it appears, releases control and disconnects when it disappears, and on iOS follows
/// the scene phase (background → release + disconnect, back to foreground → reconnect view-only).
///
/// ```swift
/// @State private var session = LiveDesktopSession(agentID: agent.id, backend: liveBackend)
/// var body: some View { LiveDesktopView(session: session) }
/// ```
public struct LiveDesktopView: View {
    private let session: LiveDesktopSession
    private let showsToolbar: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter showsToolbar: false when the app embeds `LiveDesktopToolbar` itself (e.g. in a window toolbar).
    public init(session: LiveDesktopSession, showsToolbar: Bool = true) {
        self.session = session
        self.showsToolbar = showsToolbar
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            canvas
            LiveDesktopStatusOverlay(session: session)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsToolbar && !toolbarHidden {
                LiveDesktopToolbar(session: session)
                    .padding(.horizontal, NSpace.m)
                    .padding(.vertical, NSpace.s)
                    .nGlass(cornerRadius: NRadius.l)
                    .padding(.horizontal, NSpace.m)
                    .padding(.bottom, NSpace.s)
            }
        }
        .task {
            switch session.state {
            case .idle, .ended(.leftScreen), .ended(.backgrounded): session.start()
            default: break
            }
        }
        .onDisappear {
            Task { await session.leave() }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhase(phase)
        }
        #endif
    }

    /// The keyboard's accessory row carries the controls while typing on iOS.
    private var toolbarHidden: Bool {
        #if os(iOS)
        session.isKeyboardVisible && session.inputEnabled
        #else
        false
        #endif
    }

    @ViewBuilder private var canvas: some View {
        #if os(iOS)
        DesktopCanvas(session: session, controlEnabled: session.inputEnabled,
                      keyboardVisible: session.isKeyboardVisible, paused: session.isPaused)
        #elseif os(macOS)
        DesktopCanvas(session: session, controlEnabled: session.inputEnabled, paused: session.isPaused,
                      capturesShortcuts: session.capturesSystemShortcuts, remoteCursor: session.remoteCursor)
        #endif
    }
}

/// Status over the desktop: connecting placeholder, reconnect banner, view-only / control pill, control notices,
/// and the end card with retry. Only the end card takes touches.
public struct LiveDesktopStatusOverlay: View {
    private let session: LiveDesktopSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(session: LiveDesktopSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            if showsPlaceholder {
                ConnectingPlaceholder(aspectRatio: aspectRatio)
                    .padding(NSpace.xl)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if case .ended(let reason) = session.state {
                EndedCard(reason: reason) { session.retry() }
                    .padding(NSpace.xl)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: NSpace.s) {
                HStack(alignment: .top) {
                    pill
                    Spacer(minLength: NSpace.s)
                }
                if case .reconnecting(let attempt) = session.state {
                    NBanner(String(localized: "Connection lost. Reconnecting (attempt \(attempt) of \(session.maxReconnectAttempts))…"),
                            style: .warning, symbol: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: 520, alignment: .leading)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = session.controlNotice {
                    NBanner(notice.message, style: .warning, symbol: "hand.raised.fill")
                        .frame(maxWidth: 520, alignment: .leading)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(NSpace.m)
            .allowsHitTesting(false)
        }
        .animation(NMotion.animation(NMotion.smooth, reduceMotion: reduceMotion), value: session.state)
        .animation(NMotion.animation(NMotion.smooth, reduceMotion: reduceMotion), value: session.controlNotice)
        .animation(NMotion.animation(NMotion.fade, reduceMotion: reduceMotion), value: session.hasFrame)
        .onChange(of: session.state) { old, new in
            announce(from: old, to: new)
        }
    }

    private var showsPlaceholder: Bool {
        guard !session.hasFrame else { return false }
        switch session.state {
        case .connecting, .reconnecting, .viewing, .controlling, .idle: return true
        case .ended: return false
        }
    }

    private var aspectRatio: CGFloat {
        guard let s = session.desktopSize, s.height > 0 else { return 16 / 10 }
        return s.width / s.height
    }

    @ViewBuilder private var pill: some View {
        switch session.state {
        case .viewing:
            StatusPill(text: session.isPaused ? String(localized: "Paused") : String(localized: "Watching only"),
                       symbol: session.isPaused ? "pause.fill" : "eye", prominent: false)
        case .controlling:
            StatusPill(text: String(localized: "You have control"), symbol: "hand.point.up.left.fill", prominent: true)
        case .connecting:
            StatusPill(text: String(localized: "Connecting…"), symbol: "antenna.radiowaves.left.and.right", prominent: false)
        case .reconnecting:
            StatusPill(text: String(localized: "Reconnecting…"), symbol: "arrow.triangle.2.circlepath", prominent: false)
        case .idle, .ended:
            EmptyView()
        }
    }

    private func announce(from old: LiveDesktopState, to new: LiveDesktopState) {
        let text: String?
        switch (old, new) {
        case (_, .controlling): text = String(localized: "You are controlling the desktop.")
        case (.controlling, .viewing): text = String(localized: "Control returned, watching only.")
        case (_, .reconnecting) where !(old.isReconnecting): text = String(localized: "The desktop connection dropped, reconnecting.")
        case (_, .ended): text = String(localized: "The Live Desktop is disconnected.")
        default: text = nil
        }
        if let text { AccessibilityNotification.Announcement(text).post() }
    }
}

private extension LiveDesktopState {
    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

private struct StatusPill: View {
    let text: String
    let symbol: String
    let prominent: Bool

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? NColor.onAccent : NColor.textPrimary)
            .background {
                if prominent {
                    Capsule().fill(NColor.accentGradient)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .accessibilityElement(children: .combine)
    }
}

private struct ConnectingPlaceholder: View {
    let aspectRatio: CGFloat

    var body: some View {
        VStack(spacing: NSpace.m) {
            Skeleton(cornerRadius: NRadius.m)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: 720)
            HStack(spacing: NSpace.s) {
                ProgressView().controlSize(.small)
                Text("Connecting to the agent's desktop…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to the agent's desktop")
    }
}

private struct EndedCard: View {
    let reason: LiveEndReason
    let retry: () -> Void

    private var content: (symbol: String, title: String, message: String) {
        switch reason {
        case .userDisconnected:
            ("pause.circle", String(localized: "Disconnected"), String(localized: "The Live Desktop is disconnected."))
        case .leftScreen, .backgrounded:
            ("pause.circle", String(localized: "Paused"), String(localized: "The Live Desktop reconnects when you come back to it."))
        case .connectionLost(let message):
            ("wifi.exclamationmark", String(localized: "Connection lost"), message)
        case .failed(let message):
            ("exclamationmark.triangle", String(localized: "Cannot connect"), message)
        }
    }

    var body: some View {
        NCard {
            VStack(spacing: NSpace.m) {
                Image(systemName: content.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(NColor.textSecondary)
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(NFont.headline)
                    .foregroundStyle(NColor.textPrimary)
                Text(content.message)
                    .font(.callout)
                    .foregroundStyle(NColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(NPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: 380)
        .accessibilityElement(children: .contain)
    }
}

/// Live desktop controls the app can embed (bottom bar, window toolbar…): take / release control, keyboard
/// (iOS), special keys, capture system shortcuts and fullscreen (Mac), image quality.
public struct LiveDesktopToolbar: View {
    private let session: LiveDesktopSession

    public init(session: LiveDesktopSession) {
        self.session = session
    }

    private var isControlling: Bool { session.state == .controlling }
    private var canToggleControl: Bool {
        (session.state == .viewing || session.state == .controlling) && !session.isAcquiringControl
    }

    public var body: some View {
        HStack(spacing: NSpace.s) {
            controlButton
            if session.inputEnabled {
                #if os(iOS)
                Button {
                    session.isKeyboardVisible.toggle()
                } label: {
                    Label(session.isKeyboardVisible ? "Hide keyboard" : "Keyboard", systemImage: "keyboard")
                }
                .labelStyle(.iconOnly)
                #endif
                specialKeys
                #if os(macOS)
                Toggle(isOn: Binding(get: { session.capturesSystemShortcuts },
                                     set: { session.capturesSystemShortcuts = $0 })) {
                    Label("Capture system shortcuts", systemImage: "command.square")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Send shortcuts such as ⌘Q or ⌘W to the agent's desktop")
                #endif
            }
            Spacer(minLength: 0)
            quality
            #if os(macOS)
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .labelStyle(.iconOnly)
            .help("Full screen")
            #endif
        }
        .buttonStyle(.bordered)
    }

    private var controlButton: some View {
        Button {
            Task {
                if isControlling { await session.releaseControl() } else { await session.takeControl() }
            }
        } label: {
            HStack(spacing: NSpace.xs) {
                if session.isAcquiringControl {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isControlling ? "hand.raised.slash" : "hand.point.up.left")
                }
                Text(isControlling ? "Give back control" : "Take control")
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isControlling ? NColor.danger : NColor.accent)
        .disabled(!canToggleControl)
        .accessibilityHint(isControlling ? "Gives control back to the agent; the desktop stays watch-only."
                                         : "Takes over the mouse and keyboard of the agent's desktop.")
    }

    private var specialKeys: some View {
        Menu {
            Button("Escape") { session.tap(Keysym.escape) }
            Button("Tab") { session.tap(Keysym.tab) }
            Button("Enter") { session.tap(Keysym.returnKey) }
            Button("Super") { session.tap(Keysym.superL) }
            Divider()
            Button("Ctrl+C") { session.tap(0x63, modifiers: [Keysym.controlL]) }
            Button("Ctrl+V") { session.tap(0x76, modifiers: [Keysym.controlL]) }
            Button("Ctrl+X") { session.tap(0x78, modifiers: [Keysym.controlL]) }
            Button("Ctrl+Z") { session.tap(0x7A, modifiers: [Keysym.controlL]) }
            Button("Ctrl+A") { session.tap(0x61, modifiers: [Keysym.controlL]) }
            Button("Ctrl+L") { session.tap(0x6C, modifiers: [Keysym.controlL]) }
            Divider()
            Button("Alt+Tab") { session.tap(Keysym.tab, modifiers: [Keysym.altL]) }
            Button("Alt+F4") { session.tap(Keysym.function(4), modifiers: [Keysym.altL]) }
            Menu("Function keys") {
                ForEach(1...12, id: \.self) { n in
                    Button("F\(n)") { session.tap(Keysym.function(n)) }
                }
            }
        } label: {
            Label("Special keys", systemImage: "command")
        }
        .labelStyle(.iconOnly)
    }

    private var quality: some View {
        Menu {
            Picker("Image quality", selection: Binding(get: { session.imageQuality },
                                                        set: { session.setImageQuality($0) })) {
                Text("Efficient").tag(2)
                Text("Medium").tag(5)
                Text("High").tag(7)
                Text("Highest").tag(9)
            }
        } label: {
            Label("Image quality", systemImage: "slider.horizontal.3")
        }
        .labelStyle(.iconOnly)
    }
}
