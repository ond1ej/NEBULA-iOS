import Foundation
import Synchronization

/// The ordered outgoing input channel (PointerEvent / KeyEvent) of one connection.
///
/// UI code enqueues synchronously from the main thread (order preserved: a key-down can never overtake its
/// key-up); one sender task drains it in batches. Input is accepted only while `isEnabled` — the viewer holds the
/// control lease. Disabling drops anything still queued, so nothing leaks to the agent after control ends (the
/// server-side proxy filters too; this is the client half of that boundary).
///
/// Key events are never logged.
public final class RFBInputQueue: Sendable {
    enum Item: Equatable {
        case pointer(buttons: UInt8, x: UInt16, y: UInt16)
        case key(keysym: UInt32, down: Bool)
    }

    private struct State {
        var enabled = false
        var closed = false
        var inFlight = false
        var items: [Item] = []
        var waiter: CheckedContinuation<Data?, Never>?
        var pressedKeys: Set<UInt32> = []
        var buttons: UInt8 = 0
        var lastX: UInt16 = 0
        var lastY: UInt16 = 0
    }

    /// Upper bound of queued events (a stuck transport must not grow memory without bound).
    static let maximumPending = 4096
    /// Events per WebSocket frame.
    static let batchLimit = 128

    private let state = Mutex(State())

    public init() {}

    /// True while input is accepted (control held and the connection open).
    public var isEnabled: Bool { state.withLock { $0.enabled && !$0.closed } }

    /// True when nothing is queued or being sent.
    public var isIdle: Bool { state.withLock { $0.items.isEmpty && !$0.inFlight } }

    /// Buttons currently held (as last enqueued).
    public var heldButtons: RFBPointerButtons { RFBPointerButtons(rawValue: state.withLock { $0.buttons }) }

    /// Enables or disables input. Disabling drops queued events and forgets held keys/buttons.
    public func setEnabled(_ enabled: Bool) {
        state.withLock { s in
            s.enabled = enabled && !s.closed
            if !s.enabled {
                s.items.removeAll()
                s.pressedKeys.removeAll()
                s.buttons = 0
            }
        }
    }

    /// Queues a PointerEvent (framebuffer pixel coordinates). Consecutive moves with the same buttons coalesce.
    public func pointer(x: Int, y: Int, buttons: RFBPointerButtons) {
        let px = UInt16(clamping: x), py = UInt16(clamping: y)
        enqueue { s in
            s.lastX = px
            s.lastY = py
            s.buttons = buttons.intersection(.held).rawValue
            let item = Item.pointer(buttons: buttons.rawValue, x: px, y: py)
            if case .pointer(let b, _, _)? = s.items.last, b == buttons.rawValue {
                s.items[s.items.count - 1] = item
            } else {
                guard s.items.count < Self.maximumPending else { return false }
                s.items.append(item)
            }
            return true
        }
    }

    /// Queues a KeyEvent.
    public func key(_ keysym: UInt32, down: Bool) {
        enqueue { s in
            // Key events beyond the cap are still accepted up to twice the cap, so a key-up is never lost to
            // pointer floods; past that the transport is stuck and the connection is about to fail anyway.
            guard s.items.count < Self.maximumPending * 2 else { return false }
            if down { s.pressedKeys.insert(keysym) } else { s.pressedKeys.remove(keysym) }
            s.items.append(.key(keysym: keysym, down: down))
            return true
        }
    }

    /// Queues key-ups for every held key and a pointer event without buttons (before control is released, so the
    /// agent's desktop is not left with a stuck modifier or a held mouse button).
    public func releaseAll() {
        enqueue { s in
            var changed = false
            for k in s.pressedKeys.sorted() {
                s.items.append(.key(keysym: k, down: false))
                changed = true
            }
            s.pressedKeys.removeAll()
            if s.buttons != 0 {
                s.buttons = 0
                s.items.append(.pointer(buttons: 0, x: s.lastX, y: s.lastY))
                changed = true
            }
            return changed
        }
    }

    /// Closes the queue (connection ended): drops everything and ends the sender.
    func close() {
        let waiter = state.withLock { s -> CheckedContinuation<Data?, Never>? in
            s.closed = true
            s.enabled = false
            s.items.removeAll()
            s.pressedKeys.removeAll()
            s.buttons = 0
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }

    private func enqueue(_ mutate: (inout State) -> Bool) {
        let ready = state.withLock { s -> (CheckedContinuation<Data?, Never>, Data)? in
            guard s.enabled, !s.closed, mutate(&s) else { return nil }
            guard let w = s.waiter, !s.items.isEmpty else { return nil }
            s.waiter = nil
            s.inFlight = true
            return (w, Self.takeBatch(&s.items))
        }
        if let (waiter, batch) = ready { waiter.resume(returning: batch) }
    }

    /// The sender's next batch; nil once closed.
    func nextBatch() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            enum Next { case batch(Data), end, wait(previous: CheckedContinuation<Data?, Never>?) }
            let next = state.withLock { s -> Next in
                if s.closed { return .end }
                if !s.items.isEmpty {
                    s.inFlight = true
                    return .batch(Self.takeBatch(&s.items))
                }
                s.inFlight = false
                let previous = s.waiter
                s.waiter = c
                return .wait(previous: previous)
            }
            switch next {
            case .batch(let d): c.resume(returning: d)
            case .end: c.resume(returning: nil)
            case .wait(let previous): previous?.resume(returning: nil)
            }
        }
    }

    /// The sender finished sending the last batch.
    func batchCompleted() {
        state.withLock { s in if s.items.isEmpty { s.inFlight = false } }
    }

    private static func takeBatch(_ items: inout [Item]) -> Data {
        let n = min(items.count, batchLimit)
        var out = Data()
        out.reserveCapacity(n * 8)
        for item in items.prefix(n) {
            switch item {
            case .pointer(let b, let x, let y): out.append(contentsOf: RFBClientMessage.pointerEvent(buttons: b, x: x, y: y))
            case .key(let k, let d): out.append(contentsOf: RFBClientMessage.keyEvent(keysym: k, down: d))
            }
        }
        items.removeFirst(n)
        return out
    }
}

/// Lock-free connection counters (read once per second by the session for its metrics).
public final class RFBMetrics: Sendable {
    private let bytes = Atomic<Int>(0)
    private let updates = Atomic<Int>(0)
    private let rects = Atomic<Int>(0)

    public init() {}

    public var bytesReceived: Int { bytes.load(ordering: .relaxed) }
    public var framebufferUpdates: Int { updates.load(ordering: .relaxed) }
    public var rectangles: Int { rects.load(ordering: .relaxed) }

    func addBytes(_ n: Int) { bytes.add(n, ordering: .relaxed) }
    func addUpdate(rectangles n: Int) {
        updates.add(1, ordering: .relaxed)
        rects.add(n, ordering: .relaxed)
    }
}
