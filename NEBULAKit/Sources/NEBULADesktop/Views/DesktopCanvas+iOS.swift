#if os(iOS)
import NEBULADesignSystem
import SwiftUI
import UIKit

/// SwiftUI bridge of the iOS desktop canvas. Inputs are plain values read in the parent's body, so SwiftUI calls
/// `updateUIView` exactly when they change; frames never go through SwiftUI.
struct DesktopCanvas: UIViewRepresentable {
    let session: LiveDesktopSession
    let controlEnabled: Bool
    let keyboardVisible: Bool
    let paused: Bool

    func makeUIView(context: Context) -> DesktopCanvasView {
        DesktopCanvasView(session: session)
    }

    func updateUIView(_ view: DesktopCanvasView, context: Context) {
        view.setControlEnabled(controlEnabled)
        view.setKeyboardVisible(keyboardVisible)
        view.setPaused(paused)
    }

    static func dismantleUIView(_ view: DesktopCanvasView, coordinator: ()) {
        view.teardown()
    }
}

extension KeyModifiers {
    init(_ flags: UIKeyModifierFlags) {
        var m: KeyModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.alternate) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

/// The zoomable desktop on iPhone / iPad.
///
/// View-only: pinch / double-tap zoom, pan. In control: tap = left click (two quick taps = double click),
/// two-finger tap or long press = right click, long press then drag = left drag, two-finger pan = scroll wheel,
/// one-finger pan moves the viewport, pinch still zooms; iPad pointer hover/secondary click and trackpad scrolling
/// are supported. A hidden `UIKeyInput` view provides the software keyboard and a special-keys bar; hardware
/// keyboards go through `pressesBegan/Ended`.
@MainActor
final class DesktopCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, DisplayLinkClient {
    private weak var session: LiveDesktopSession?
    private let presenter: FramePresenter
    private let scrollView = UIScrollView()
    private let imageView = UIView()
    private let keyboardProxy = KeyboardProxyView()

    private var framebufferSize: CGSize = .zero
    private var lastBoundsSize: CGSize = .zero
    private var controlEnabled = false
    private var keyboardVisible = false
    private var keys = PressedKeyTracker()
    private var latchedModifiers: [UInt32] = []
    private var wheelRemainder = CGPoint.zero
    private var drag: (origin: CGPoint, start: FramebufferPoint, active: Bool)?
    private var lastTap: (time: CFTimeInterval, location: CGPoint, point: FramebufferPoint)?

    private lazy var zoomTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleZoomTap(_:)))
        g.numberOfTapsRequired = 2
        return g
    }()
    private lazy var clickTap = UITapGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    private lazy var secondaryClick: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        g.buttonMaskRequired = .secondary
        return g
    }()
    private lazy var twoFingerTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        g.numberOfTouchesRequired = 2
        return g
    }()
    private lazy var longPress: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        g.minimumPressDuration = 0.45
        return g
    }()
    private lazy var wheelPan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        g.minimumNumberOfTouches = 2
        g.maximumNumberOfTouches = 2
        return g
    }()
    /// Trackpad / mouse-wheel scrolling on iPad (indirect scroll events only, no touches).
    private lazy var scrollEventsPan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        g.allowedScrollTypesMask = .all
        g.allowedTouchTypes = []
        return g
    }()
    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))

    init(session: LiveDesktopSession) {
        self.session = session
        presenter = FramePresenter(mailbox: session.mailbox)
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true

        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .black
        scrollView.delaysContentTouches = false
        addSubview(scrollView)

        imageView.backgroundColor = .black
        imageView.layer.contentsGravity = .resize
        imageView.layer.magnificationFilter = .linear
        imageView.layer.minificationFilter = .linear
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "The agent's Live Desktop")
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        keyboardProxy.alpha = 0
        keyboardProxy.isAccessibilityElement = false
        keyboardProxy.onText = { [weak self] text in self?.typeText(text) }
        keyboardProxy.onBackspace = { [weak self] in self?.tapKey(Keysym.backSpace) }
        keyboardProxy.onPresses = { [weak self] presses, down in self?.handlePresses(presses, down: down) ?? presses }
        keyboardProxy.onResign = { [weak self] in self?.keyboardDidHide() }
        keyboardProxy.accessory.onKey = { [weak self] keysym in self?.tapKey(keysym) }
        keyboardProxy.accessory.onModifier = { [weak self] keysym in self?.toggleModifier(keysym) }
        keyboardProxy.accessory.onHide = { [weak self] in self?.session?.isKeyboardVisible = false }
        addSubview(keyboardProxy)

        for g in [zoomTap, clickTap, secondaryClick, twoFingerTap, longPress, wheelPan, scrollEventsPan, hover] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        clickTap.require(toFail: longPress)
        presenter.onFrame = { [weak self] frame in self?.present(frame) }
        applyControlMode()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Display link

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard presenter.link == nil else { return }
            let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            presenter.link = link
        } else {
            presenter.link?.invalidate()
            presenter.link = nil
        }
    }

    func displayLinkDidFire() { presenter.tick() }

    func setPaused(_ paused: Bool) {
        if presenter.isPaused != paused { presenter.isPaused = paused }
    }

    func teardown() {
        releaseKeys()
        presenter.detach()
    }

    private func present(_ frame: DesktopFrame) {
        imageView.layer.contents = frame.image
        let size = CGSize(width: frame.width, height: frame.height)
        if size != framebufferSize {
            framebufferSize = size
            relayoutContent()
        }
    }

    // MARK: Zoom & layout

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        keyboardProxy.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        if bounds.size != lastBoundsSize {
            let atFit = lastBoundsSize == .zero || abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.0001
            lastBoundsSize = bounds.size
            updateZoomLimits(resetToFit: atFit)
        }
    }

    private func relayoutContent() {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        scrollView.minimumZoomScale = 0.001
        scrollView.maximumZoomScale = 1000
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: framebufferSize)
        scrollView.contentSize = framebufferSize
        updateZoomLimits(resetToFit: true)
    }

    private func updateZoomLimits(resetToFit: Bool) {
        guard framebufferSize.width > 0, framebufferSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 8, 4)
        if resetToFit || scrollView.zoomScale < fit {
            scrollView.zoomScale = fit
        } else if scrollView.zoomScale > scrollView.maximumZoomScale {
            scrollView.zoomScale = scrollView.maximumZoomScale
        }
        centerContent()
        updateFilters()
    }

    private func centerContent() {
        let content = scrollView.contentSize
        let dx = max((scrollView.bounds.width - content.width) / 2, 0)
        let dy = max((scrollView.bounds.height - content.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    private func updateFilters() {
        // Crisp text when zoomed in, smooth when scaled down.
        imageView.layer.magnificationFilter = scrollView.zoomScale >= 2 ? .nearest : .linear
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateFilters()
    }

    // MARK: Mode

    func setControlEnabled(_ enabled: Bool) {
        guard enabled != controlEnabled else { return }
        controlEnabled = enabled
        applyControlMode()
    }

    private func applyControlMode() {
        let on = controlEnabled
        zoomTap.isEnabled = !on
        for g in [clickTap, secondaryClick, twoFingerTap, longPress, wheelPan, scrollEventsPan, hover] as [UIGestureRecognizer] {
            g.isEnabled = on
        }
        scrollView.panGestureRecognizer.maximumNumberOfTouches = on ? 1 : Int.max
        imageView.accessibilityTraits = on ? [.image, .allowsDirectInteraction] : [.image]
        imageView.accessibilityHint = on ? String(localized: "Tap to click; press and hold, then drag to drag.") : nil
        if on {
            DispatchQueue.main.async { [weak self] in self?.claimKeyboardFocus() }
        } else {
            releaseKeys()
            latchedModifiers.removeAll()
            keyboardProxy.accessory.setLatched([])
            drag = nil
            if keyboardProxy.isFirstResponder { _ = keyboardProxy.resignFirstResponder() }
            if isFirstResponder { _ = resignFirstResponder() }
        }
    }

    override var canBecomeFirstResponder: Bool { controlEnabled }

    private func claimKeyboardFocus() {
        guard controlEnabled, window != nil else { return }
        if keyboardVisible {
            if !keyboardProxy.isFirstResponder { _ = keyboardProxy.becomeFirstResponder() }
        } else if !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }

    func setKeyboardVisible(_ visible: Bool) {
        guard visible != keyboardVisible else { return }
        keyboardVisible = visible
        if visible {
            DispatchQueue.main.async { [weak self] in self?.claimKeyboardFocus() }
        } else if keyboardProxy.isFirstResponder {
            _ = keyboardProxy.resignFirstResponder()
            if controlEnabled { _ = becomeFirstResponder() }
        }
    }

    private func keyboardDidHide() {
        if keyboardVisible {
            keyboardVisible = false
            session?.isKeyboardVisible = false
        }
    }

    // MARK: Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === hover || other === hover
    }

    private func point(_ g: UIGestureRecognizer) -> FramebufferPoint? {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return nil }
        return DesktopGeometry.framebufferPoint(forContentPoint: g.location(in: imageView),
                                                contentSize: imageView.bounds.size, framebufferSize: framebufferSize)
    }

    @objc private func handleZoomTap(_ g: UITapGestureRecognizer) {
        guard !controlEnabled, framebufferSize.width > 0 else { return }
        let animated = !UIAccessibility.isReduceMotionEnabled
        let minScale = scrollView.minimumZoomScale
        if scrollView.zoomScale > minScale * 1.05 {
            scrollView.setZoomScale(minScale, animated: animated)
        } else {
            let target = min(scrollView.maximumZoomScale, minScale * 2.5)
            let p = g.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
            scrollView.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: animated)
        }
    }

    @objc private func handleClick(_ g: UITapGestureRecognizer) {
        guard controlEnabled, let session, var target = point(g) else { return }
        let now = CACurrentMediaTime()
        let location = g.location(in: self)
        // A quick second tap reuses the first point, so the desktop sees a clean double click.
        if let last = lastTap, now - last.time < 0.4,
           hypot(location.x - last.location.x, location.y - last.location.y) < 16 {
            target = last.point
        }
        lastTap = (now, location, target)
        session.click(at: target, button: .left)
    }

    @objc private func handleRightClick(_ g: UITapGestureRecognizer) {
        guard controlEnabled, let session, let target = point(g) else { return }
        session.click(at: target, button: .right)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard controlEnabled, let session else { return }
        let location = g.location(in: self)
        switch g.state {
        case .began:
            guard let start = point(g) else { return }
            drag = (location, start, false)
            Haptics.soft()
        case .changed:
            guard var d = drag else { return }
            if !d.active, hypot(location.x - d.origin.x, location.y - d.origin.y) > 8 {
                d.active = true
                drag = d
                session.pointer(at: d.start, buttons: [])
                session.pointer(at: d.start, buttons: .left)
            }
            if d.active, let p = point(g) { session.pointer(at: p, buttons: .left) }
        case .ended:
            guard let d = drag else { return }
            if d.active {
                session.pointer(at: point(g) ?? d.start, buttons: [])
            } else {
                session.click(at: d.start, button: .right)
            }
            drag = nil
        case .cancelled, .failed:
            if let d = drag, d.active { session.pointer(at: point(g) ?? d.start, buttons: []) }
            drag = nil
        default:
            break
        }
    }

    @objc private func handleWheel(_ g: UIPanGestureRecognizer) {
        guard controlEnabled, let session else { return }
        switch g.state {
        case .began:
            wheelRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            wheelRemainder.x += t.x
            wheelRemainder.y += t.y
            guard let p = point(g) else { return }
            let step: CGFloat = 18
            // Natural scrolling: fingers down → content down → wheel up.
            while wheelRemainder.y >= step { session.scroll(at: p, direction: .wheelUp); wheelRemainder.y -= step }
            while wheelRemainder.y <= -step { session.scroll(at: p, direction: .wheelDown); wheelRemainder.y += step }
            while wheelRemainder.x >= step { session.scroll(at: p, direction: .wheelLeft); wheelRemainder.x -= step }
            while wheelRemainder.x <= -step { session.scroll(at: p, direction: .wheelRight); wheelRemainder.x += step }
        default:
            wheelRemainder = .zero
        }
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard controlEnabled, let session, drag == nil, let p = point(g) else { return }
        switch g.state {
        case .began, .changed: session.pointer(at: p, buttons: [])
        default: break
        }
    }

    // MARK: Keyboard

    private func consumeModifiers() -> [UInt32] {
        let mods = latchedModifiers
        if !mods.isEmpty {
            latchedModifiers.removeAll()
            keyboardProxy.accessory.setLatched([])
        }
        return mods
    }

    private func toggleModifier(_ keysym: UInt32) {
        if let i = latchedModifiers.firstIndex(of: keysym) {
            latchedModifiers.remove(at: i)
        } else {
            latchedModifiers.append(keysym)
        }
        keyboardProxy.accessory.setLatched(latchedModifiers)
        Haptics.selection()
    }

    private func tapKey(_ keysym: UInt32) {
        guard controlEnabled, let session else { return }
        session.tap(keysym, modifiers: consumeModifiers())
    }

    private func typeText(_ text: String) {
        // While hardware keys are down their presses already reached the desktop; skip the echoed text.
        guard controlEnabled, keys.isEmpty, let session else { return }
        session.type(text, modifiers: consumeModifiers())
    }

    private func releaseKeys() {
        guard let session else { return }
        keys.releaseAll { session.key($0, down: $1) }
    }

    /// Hardware keyboard: returns the presses that were not handled.
    fileprivate func handlePresses(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        guard controlEnabled, let session else { return presses }
        var unhandled = Set<UIPress>()
        let send: (UInt32, Bool) -> Void = { session.key($0, down: $1) }
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let code = key.keyCode.rawValue
            if down {
                let resolution = HardwareKeyResolver.resolve(code: code, table: .hid, characters: key.characters,
                                                             charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                                             modifiers: KeyModifiers(key.modifierFlags))
                if !keys.keyDown(code: code, resolution: resolution, send: send) { unhandled.insert(press) }
            } else if !keys.keyUp(code: code, send: send) {
                unhandled.insert(press)
            }
        }
        return unhandled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handlePresses(presses, down: true)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handlePresses(presses, down: false)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handlePresses(presses, down: false)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    override func resignFirstResponder() -> Bool {
        if !keyboardProxy.isFirstResponder { releaseKeys() }
        return super.resignFirstResponder()
    }
}

/// An invisible first responder that brings up the software keyboard (no autocorrection, no smart punctuation:
/// every keystroke goes to the desktop as typed).
@MainActor
final class KeyboardProxyView: UIView, UIKeyInput {
    var onText: (@MainActor (String) -> Void)?
    var onBackspace: (@MainActor () -> Void)?
    var onPresses: (@MainActor (Set<UIPress>, Bool) -> Set<UIPress>)?
    var onResign: (@MainActor () -> Void)?
    let accessory = SpecialKeysBar()

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

    var hasText: Bool { true } // backspace always reaches the desktop
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = onPresses?(presses, true) ?? presses
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = onPresses?(presses, false) ?? presses
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = onPresses?(presses, false) ?? presses
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}

/// The keyboard accessory row: Esc, Tab, sticky Ctrl / Alt / Super, arrows, Enter, Backspace, F-keys, hide.
@MainActor
final class SpecialKeysBar: UIInputView {
    var onKey: (@MainActor (UInt32) -> Void)?
    var onModifier: (@MainActor (UInt32) -> Void)?
    var onHide: (@MainActor () -> Void)?
    private var modifierButtons: [UInt32: UIButton] = [:]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)

        let key: (String?, String?, String, UInt32) -> UIButton = { [unowned self] title, symbol, label, keysym in
            self.makeButton(title: title, symbol: symbol, label: label) { [weak self] in self?.onKey?(keysym) }
        }
        let modifier: (String, String, UInt32) -> UIButton = { [unowned self] title, label, keysym in
            let b = self.makeButton(title: title, symbol: nil, label: label) { [weak self] in self?.onModifier?(keysym) }
            b.accessibilityTraits.insert(.button)
            self.modifierButtons[keysym] = b
            return b
        }
        let fkeys = makeButton(title: "F1–F12", symbol: nil, label: String(localized: "Function keys")) {}
        fkeys.menu = UIMenu(title: String(localized: "Function keys"), children: (1...12).map { n in
            UIAction(title: "F\(n)") { [weak self] _ in self?.onKey?(Keysym.function(n)) }
        })
        fkeys.showsMenuAsPrimaryAction = true
        let hide = makeButton(title: nil, symbol: "keyboard.chevron.compact.down", label: String(localized: "Hide keyboard")) {
            [weak self] in self?.onHide?()
        }
        let buttons: [UIButton] = [
            key("Esc", nil, "Escape", Keysym.escape),
            key("Tab", nil, String(localized: "Tab key"), Keysym.tab),
            modifier("Ctrl", String(localized: "Control (hold for the next key)"), Keysym.controlL),
            modifier("Alt", String(localized: "Alt (hold for the next key)"), Keysym.altL),
            modifier("Super", String(localized: "Super (hold for the next key)"), Keysym.superL),
            key(nil, "arrow.left", String(localized: "Left arrow"), Keysym.left),
            key(nil, "arrow.up", String(localized: "Up arrow"), Keysym.up),
            key(nil, "arrow.down", String(localized: "Down arrow"), Keysym.down),
            key(nil, "arrow.right", String(localized: "Right arrow"), Keysym.right),
            key(nil, "return", "Enter", Keysym.returnKey),
            key(nil, "delete.left", "Backspace", Keysym.backSpace),
            fkeys,
            hide,
        ]
        buttons.forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: min(UIFontMetrics.default.scaledValue(for: 52), 80))
    }

    func setLatched(_ keysyms: [UInt32]) {
        for (k, b) in modifierButtons {
            b.isSelected = keysyms.contains(k)
            b.accessibilityValue = b.isSelected ? String(localized: "held") : nil
        }
    }

    private func makeButton(title: String?, symbol: String?, label: String,
                            action: @escaping @MainActor () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = symbol.map { UIImage(systemName: $0) } ?? nil
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = UIFont.preferredFont(forTextStyle: .callout)
            return a
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.configurationUpdateHandler = { b in
            var c = b.configuration
            c?.baseBackgroundColor = b.isSelected ? b.tintColor : nil
            c?.baseForegroundColor = b.isSelected ? .white : nil
            b.configuration = c
        }
        return button
    }
}
#endif
