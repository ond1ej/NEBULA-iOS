import Foundation
import QuartzCore

/// Receives display-link callbacks (the link retains a proxy, never the view).
@MainActor
protocol DisplayLinkClient: AnyObject {
    func displayLinkDidFire()
}

@MainActor
final class DisplayLinkProxy: NSObject {
    weak var client: (any DisplayLinkClient)?

    init(_ client: any DisplayLinkClient) {
        self.client = client
    }

    @objc func tick(_ link: CADisplayLink) {
        if let client { client.displayLinkDidFire() } else { link.invalidate() }
    }
}

/// Moves frames from the mailbox to a layer at most once per display refresh, and stops the display link while
/// nothing changes (no CPU on a static desktop). No SwiftUI involvement per frame.
@MainActor
final class FramePresenter {
    /// Ticks without a new frame before the display link is paused (~0.25–0.5 s).
    private static let idleTicksBeforeSleep = 30

    let mailbox: FrameMailbox
    var link: CADisplayLink? {
        didSet { if link != nil { wake() } }
    }
    /// Externally paused (session paused / view hidden).
    var isPaused = false {
        didSet {
            if isPaused { link?.isPaused = true } else { wake() }
        }
    }
    var onFrame: ((DesktopFrame) -> Void)?

    private var lastGeneration: UInt64 = 0
    private var idleTicks = 0

    init(mailbox: FrameMailbox) {
        self.mailbox = mailbox
        mailbox.setWakeHandler(owner: self) { [weak self] in
            Task { @MainActor in self?.wake() }
        }
    }

    func tick() {
        if let next = mailbox.takeFrame(newerThan: lastGeneration) {
            lastGeneration = next.generation
            idleTicks = 0
            onFrame?(next.frame)
            return
        }
        idleTicks += 1
        if idleTicks >= Self.idleTicksBeforeSleep, mailbox.prepareToSleep(lastSeen: lastGeneration) {
            link?.isPaused = true
        }
    }

    func wake() {
        guard !isPaused, let link else { return }
        mailbox.consumerDidWake()
        idleTicks = 0
        link.isPaused = false
    }

    func detach() {
        mailbox.removeWakeHandler(owner: self)
        link?.invalidate()
        link = nil
    }
}
