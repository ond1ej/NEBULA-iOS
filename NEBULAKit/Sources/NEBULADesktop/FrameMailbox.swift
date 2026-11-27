import CoreGraphics
import Foundation
import Synchronization

/// One decoded desktop frame, ready for `CALayer.contents`.
public struct DesktopFrame: @unchecked Sendable {
    // CGImage is immutable and thread-safe; the wrapper only makes that explicit for strict concurrency.
    public let image: CGImage
    public let width: Int
    public let height: Int
    /// The region that changed since the previous published frame (framebuffer pixels, top-left origin).
    public let dirtyRect: CGRect?
}

/// The hand-off between the decoder (producer, decode executor) and the renderer (consumer, display link on the
/// main thread). Latest frame wins; at most one snapshot is produced per presented frame:
///
/// * the producer publishes only when the consumer has taken the previous frame, otherwise it just marks
///   "pending changes";
/// * when the consumer takes a frame and changes are pending, it asks the producer for a fresh snapshot;
/// * an idle consumer (display link paused) is woken when a frame is published.
///
/// So nothing is copied while nobody is watching, and the display link sleeps while the desktop is static.
public final class FrameMailbox: Sendable {
    private struct State {
        var frame: DesktopFrame?
        var generation: UInt64 = 0
        var consumedGeneration: UInt64 = 0
        var pendingChanges = false
        var consumerSleeping = true
        var wake: (@Sendable () -> Void)?
        var wakeOwner: ObjectIdentifier?
        var producer: ObjectIdentifier?
        var snapshotRequest: (@Sendable () -> Void)?
        var presented = 0
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: Producer

    func attachProducer(_ id: ObjectIdentifier, requestSnapshot: @escaping @Sendable () -> Void) {
        state.withLock { s in
            s.producer = id
            s.snapshotRequest = requestSnapshot
            s.pendingChanges = false
        }
    }

    func detachProducer(_ id: ObjectIdentifier) {
        state.withLock { s in
            guard s.producer == id else { return }
            s.producer = nil
            s.snapshotRequest = nil
            s.pendingChanges = false
        }
    }

    /// Atomically: returns true when a new frame may be published now; otherwise records that changes are pending
    /// (the consumer will request a snapshot once it has taken the current frame).
    func reserveOrDefer() -> Bool {
        state.withLock { s in
            if s.frame == nil || s.consumedGeneration == s.generation { return true }
            s.pendingChanges = true
            return false
        }
    }

    func publish(_ frame: DesktopFrame) {
        let wake = state.withLock { s -> (@Sendable () -> Void)? in
            s.frame = frame
            s.generation &+= 1
            s.pendingChanges = false
            guard s.consumerSleeping else { return nil }
            s.consumerSleeping = false
            return s.wake
        }
        wake?()
    }

    // MARK: Consumer

    /// Installs the consumer's wake-up (called on the producer's thread; the consumer hops to the main thread).
    /// The latest consumer wins.
    public func setWakeHandler(owner: AnyObject, _ wake: @escaping @Sendable () -> Void) {
        let id = ObjectIdentifier(owner)
        state.withLock { s in
            s.wake = wake
            s.wakeOwner = id
        }
    }

    /// Removes the wake-up of `owner` (a newer consumer's handler stays).
    public func removeWakeHandler(owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        state.withLock { s in
            guard s.wakeOwner == id else { return }
            s.wake = nil
            s.wakeOwner = nil
        }
    }

    /// The newest frame if it is newer than `generation`. Taking it may request a fresh snapshot from the producer.
    public func takeFrame(newerThan generation: UInt64) -> (frame: DesktopFrame, generation: UInt64)? {
        let (result, request) = state.withLock { s -> ((DesktopFrame, UInt64)?, (@Sendable () -> Void)?) in
            guard let frame = s.frame, s.generation > generation else { return (nil, nil) }
            s.consumedGeneration = s.generation
            s.presented += 1
            var request: (@Sendable () -> Void)?
            if s.pendingChanges {
                s.pendingChanges = false
                request = s.snapshotRequest
            }
            return ((frame, s.generation), request)
        }
        request?()
        return result.map { (frame: $0.0, generation: $0.1) }
    }

    /// The consumer wants to pause its display link. Returns false (do not sleep) if a newer frame arrived meanwhile.
    public func prepareToSleep(lastSeen generation: UInt64) -> Bool {
        state.withLock { s in
            if s.generation > generation { return false }
            s.consumerSleeping = true
            return true
        }
    }

    /// The consumer's display link runs again.
    public func consumerDidWake() {
        state.withLock { $0.consumerSleeping = false }
    }

    /// Number of frames handed to a renderer so far (for the FPS metric).
    public var presentedFrameCount: Int { state.withLock { $0.presented } }

    /// The newest frame regardless of generation (e.g. a freshly created view).
    public var latestFrame: DesktopFrame? { state.withLock { $0.frame } }
}
