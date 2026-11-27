#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI bridge of the Mac desktop canvas.
struct DesktopCanvas: NSViewRepresentable {
    let session: LiveDesktopSession
    let controlEnabled: Bool
    let paused: Bool
    let capturesShortcuts: Bool
    let remoteCursor: RemoteCursor?

    func makeNSView(context: Context) -> DesktopNSView {
        DesktopNSView(session: session)
    }

    func updateNSView(_ view: DesktopNSView, context: Context) {
        view.capturesShortcuts = capturesShortcuts
        view.setRemoteCursor(remoteCursor)
        view.setControlEnabled(controlEnabled)
        view.setPaused(paused)
    }

    static func dismantleNSView(_ view: DesktopNSView, coordinator: ()) {
        view.teardown()
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: KeyModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

/// The desktop on the Mac: a layer-hosting view (aspect fit via `contentsGravity`, follows window resizing and
/// fullscreen), mouse / wheel / keyboard → RFB while in control.
///
/// Command is sent as Super. Without "capture keyboard", app shortcuts (Cmd+Q, Cmd+W, …) stay with the app and a
/// lone Command press is not forwarded (Super is only sent together with another key); with capture on, every
/// shortcut the system lets through goes to the desktop.
@MainActor
final class DesktopNSView: NSView, DisplayLinkClient {
    private weak var session: LiveDesktopSession?
    private let presenter: FramePresenter
    private(set) var framebufferSize: CGSize = .zero
    private var controlEnabled = false
    var capturesShortcuts = false
    private var buttons: RFBPointerButtons = []
    private var wheelRemainder = CGPoint.zero
    private var keys = PressedKeyTracker()
    /// Command keys pressed but not yet forwarded (non-capture mode: forwarded with the next key).
    private var pendingCommandKeys: Set<UInt16> = []
    private var trackingArea: NSTrackingArea?
    private var observers: [any NSObjectProtocol] = []
    private var cursor: NSCursor = DesktopNSView.dotCursor
    private var cursorImage: CGImage?

    init(session: LiveDesktopSession) {
        self.session = session
        presenter = FramePresenter(mailbox: session.mailbox)
        super.init(frame: .zero)
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        host.contentsGravity = .resizeAspect
        host.magnificationFilter = .linear
        host.minificationFilter = .linear
        host.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer = host
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "The agent's Live Desktop"))
        presenter.onFrame = { [weak self] frame in self?.present(frame) }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { controlEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { controlEnabled }

    // MARK: Display link & window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else {
            presenter.link?.invalidate()
            presenter.link = nil
            return
        }
        if presenter.link == nil {
            let link = displayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            presenter.link = link
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAllInput() }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        })
    }

    private func occlusionChanged() {
        guard let window, let session else { return }
        if window.occlusionState.contains(.visible) { session.resume() } else { session.pause() }
    }

    func displayLinkDidFire() { presenter.tick() }

    func setPaused(_ paused: Bool) {
        if presenter.isPaused != paused { presenter.isPaused = paused }
    }

    func teardown() {
        releaseAllInput()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        presenter.detach()
    }

    private func present(_ frame: DesktopFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame.image
        CATransaction.commit()
        framebufferSize = CGSize(width: frame.width, height: frame.height)
    }

    // MARK: Mode & cursor

    func setControlEnabled(_ enabled: Bool) {
        guard enabled != controlEnabled else { return }
        controlEnabled = enabled
        if enabled {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controlEnabled else { return }
                self.window?.makeFirstResponder(self)
            }
        } else {
            releaseAllInput()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        window?.invalidateCursorRects(for: self)
    }

    func setRemoteCursor(_ remote: RemoteCursor?) {
        guard remote?.image !== cursorImage || (remote == nil) != (cursorImage == nil) else { return }
        cursorImage = remote?.image
        let new: NSCursor
        if let remote {
            let image = NSImage(cgImage: remote.image, size: NSSize(width: remote.image.width, height: remote.image.height))
            new = NSCursor(image: image, hotSpot: NSPoint(x: remote.hotspotX, y: remote.hotspotY))
        } else {
            new = Self.dotCursor
        }
        cursor = new
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if controlEnabled { addCursorRect(bounds, cursor: cursor) }
    }

    /// A small dot: the desktop draws its own pointer into the image, the dot marks the local position.
    private static let dotCursor: NSCursor = {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 4))
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Mouse

    private func point(_ event: NSEvent, clamp: Bool) -> FramebufferPoint? {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return DesktopGeometry(framebufferSize: framebufferSize, viewSize: bounds.size)
            .framebufferPoint(forViewPoint: p, clampToEdges: clamp)
    }

    private func sendPointer(_ event: NSEvent) {
        guard controlEnabled, let session, let p = point(event, clamp: !buttons.isEmpty) else { return }
        session.pointer(at: p, buttons: buttons)
    }

    private func press(_ button: RFBPointerButtons, _ event: NSEvent) {
        guard controlEnabled else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard point(event, clamp: false) != nil || !buttons.isEmpty else { return } // ignore clicks in the letterbox
        buttons.insert(button)
        sendPointer(event)
    }

    private func release(_ button: RFBPointerButtons, _ event: NSEvent) {
        guard controlEnabled, buttons.contains(button) else { return }
        buttons.remove(button)
        guard let session, let p = point(event, clamp: true) else { return }
        session.pointer(at: p, buttons: buttons)
    }

    override func mouseMoved(with event: NSEvent) { controlEnabled ? sendPointer(event) : super.mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { controlEnabled ? sendPointer(event) : super.mouseDragged(with: event) }
    override func rightMouseDragged(with event: NSEvent) {
        controlEnabled ? sendPointer(event) : super.rightMouseDragged(with: event)
    }
    override func otherMouseDragged(with event: NSEvent) {
        controlEnabled ? sendPointer(event) : super.otherMouseDragged(with: event)
    }

    override func mouseDown(with event: NSEvent) { controlEnabled ? press(.left, event) : super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { controlEnabled ? release(.left, event) : super.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        controlEnabled ? press(.right, event) : super.rightMouseDown(with: event)
    }
    override func rightMouseUp(with event: NSEvent) {
        controlEnabled ? release(.right, event) : super.rightMouseUp(with: event)
    }
    override func otherMouseDown(with event: NSEvent) {
        guard controlEnabled, event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        press(.middle, event)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard controlEnabled, event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        release(.middle, event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard controlEnabled, let session, let p = point(event, clamp: true) else {
            return super.scrollWheel(with: event)
        }
        if event.phase == .began { wheelRemainder = .zero }
        // Precise (trackpad) deltas are points; classic wheels report lines.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        wheelRemainder.x += event.scrollingDeltaX
        wheelRemainder.y += event.scrollingDeltaY
        // scrollingDelta follows the user's natural-scrolling setting: positive y = content moves down = wheel up.
        while wheelRemainder.y >= step { session.scroll(at: p, direction: .wheelUp); wheelRemainder.y -= step }
        while wheelRemainder.y <= -step { session.scroll(at: p, direction: .wheelDown); wheelRemainder.y += step }
        while wheelRemainder.x >= step { session.scroll(at: p, direction: .wheelLeft); wheelRemainder.x -= step }
        while wheelRemainder.x <= -step { session.scroll(at: p, direction: .wheelRight); wheelRemainder.x += step }
    }

    // MARK: Keyboard

    private func flushPendingCommand(_ send: (UInt32, Bool) -> Void) {
        for code in pendingCommandKeys.sorted() {
            if let k = Keysym.macSpecial(keyCode: code) { keys.press(code: Int(code), keysym: k, send: send) }
        }
        pendingCommandKeys.removeAll()
    }

    override func keyDown(with event: NSEvent) {
        guard controlEnabled, let session else { return super.keyDown(with: event) }
        let send: (UInt32, Bool) -> Void = { session.key($0, down: $1) }
        let command = event.modifierFlags.contains(.command)
        if command { flushPendingCommand(send) }
        let resolution = HardwareKeyResolver.resolve(code: Int(event.keyCode), table: .mac,
                                                     characters: event.characters ?? "",
                                                     charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                                     modifiers: KeyModifiers(event.modifierFlags))
        // AppKit sends no keyUp for keys pressed with Command held: send those as a tap.
        _ = keys.keyDown(code: Int(event.keyCode), resolution: resolution, tapOnly: command, send: send)
    }

    override func keyUp(with event: NSEvent) {
        guard controlEnabled, let session else { return super.keyUp(with: event) }
        _ = keys.keyUp(code: Int(event.keyCode)) { session.key($0, down: $1) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard controlEnabled, let session else { return super.flagsChanged(with: event) }
        let code = event.keyCode
        let send: (UInt32, Bool) -> Void = { session.key($0, down: $1) }
        if code == 0x39 { // Caps Lock: each change toggles the remote state
            send(Keysym.capsLock, true)
            send(Keysym.capsLock, false)
            return
        }
        guard let keysym = Keysym.macSpecial(keyCode: code), Keysym.modifiers.contains(keysym),
              let mask = Keysym.macModifierDeviceMask(keyCode: code) else { return }
        let isDown = event.modifierFlags.rawValue & mask != 0
        if (keysym == Keysym.superL || keysym == Keysym.superR) && !capturesShortcuts {
            if isDown {
                pendingCommandKeys.insert(code)
            } else {
                pendingCommandKeys.remove(code)
                _ = keys.keyUp(code: Int(code), send: send)
            }
            return
        }
        if isDown {
            if !keys.isPressed(code: Int(code)) { keys.press(code: Int(code), keysym: keysym, send: send) }
        } else {
            _ = keys.keyUp(code: Int(code), send: send)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard controlEnabled, capturesShortcuts, event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseAllInput()
        return super.resignFirstResponder()
    }

    /// Lifts held keys and buttons (focus lost, window deactivated, control ended).
    private func releaseAllInput() {
        pendingCommandKeys.removeAll()
        guard let session else { return }
        keys.releaseAll { session.key($0, down: $1) }
        if !buttons.isEmpty {
            buttons = []
            session.releaseHeldInput()
        }
        wheelRemainder = .zero
    }
}
#endif
