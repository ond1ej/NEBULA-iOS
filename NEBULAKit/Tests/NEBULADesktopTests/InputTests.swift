import CoreGraphics
import Foundation
@testable import NEBULADesktop
import Testing

@Suite("Keysyms")
struct KeysymTests {
    @Test("Printable ASCII and Latin-1 map to their code points")
    func asciiLatin1() {
        for scalar in (0x20...0x7E).compactMap(Unicode.Scalar.init) {
            #expect(Keysym.forScalar(scalar) == scalar.value)
        }
        #expect(Keysym.forText("é") == [0xE9])
        #expect(Keysym.forText("ü") == [0xFC])
        #expect(Keysym.forText("ß") == [0xDF])
        #expect(Keysym.forText("\u{A0}") == [0xA0])
    }

    @Test("Other Unicode maps to 0x01000000 + code point (Czech, €, emoji)")
    func unicode() {
        #expect(Keysym.forText("ě") == [0x0100_011B])
        #expect(Keysym.forText("ř") == [0x0100_0159])
        #expect(Keysym.forText("€") == [0x0100_20AC])
        #expect(Keysym.forText("😀") == [0x0101_F600])
        #expect(Keysym.forText("e\u{301}") == [0xE9]) // NFC first
        #expect(Keysym.forText("Ahoj") == [0x41, 0x68, 0x6F, 0x6A])
    }

    @Test("Control characters map to keys or are dropped")
    func controls() {
        #expect(Keysym.forText("\n") == [Keysym.returnKey])
        #expect(Keysym.forText("\r") == [Keysym.returnKey])
        #expect(Keysym.forText("\t") == [Keysym.tab])
        #expect(Keysym.forText("\u{1B}") == [Keysym.escape])
        #expect(Keysym.forText("\u{7F}") == [Keysym.delete])
        #expect(Keysym.forText("\u{01}\u{85}") == [])
        #expect(Keysym.forText("\u{F700}") == []) // NSUpArrowFunctionKey
    }

    @Test("Special keysym values")
    func specialValues() {
        #expect(Keysym.returnKey == 0xFF0D)
        #expect(Keysym.backSpace == 0xFF08)
        #expect(Keysym.tab == 0xFF09)
        #expect(Keysym.escape == 0xFF1B)
        #expect(Keysym.delete == 0xFFFF)
        #expect(Keysym.function(1) == 0xFFBE)
        #expect(Keysym.function(12) == 0xFFC9)
        #expect(Keysym.shiftL == 0xFFE1 && Keysym.controlL == 0xFFE3 && Keysym.altL == 0xFFE9 && Keysym.superL == 0xFFEB)
        #expect([Keysym.left, Keysym.up, Keysym.right, Keysym.down] == [0xFF51, 0xFF52, 0xFF53, 0xFF54])
        #expect([Keysym.home, Keysym.pageUp, Keysym.pageDown, Keysym.end] == [0xFF50, 0xFF55, 0xFF56, 0xFF57])
    }

    @Test("Mac key codes")
    func macTable() {
        let expected: [UInt16: UInt32] = [
            0x24: 0xFF0D, 0x33: 0xFF08, 0x30: 0xFF09, 0x35: 0xFF1B, 0x75: 0xFFFF, 0x7B: 0xFF51, 0x7E: 0xFF52,
            0x7C: 0xFF53, 0x7D: 0xFF54, 0x73: 0xFF50, 0x77: 0xFF57, 0x74: 0xFF55, 0x79: 0xFF56, 0x7A: 0xFFBE,
            0x78: 0xFFBF, 0x63: 0xFFC0, 0x76: 0xFFC1, 0x60: 0xFFC2, 0x61: 0xFFC3, 0x62: 0xFFC4, 0x64: 0xFFC5,
            0x65: 0xFFC6, 0x6D: 0xFFC7, 0x67: 0xFFC8, 0x6F: 0xFFC9, 0x38: 0xFFE1, 0x3C: 0xFFE2, 0x3B: 0xFFE3,
            0x3E: 0xFFE4, 0x3A: 0xFFE9, 0x3D: 0xFFEA, 0x37: 0xFFEB, 0x36: 0xFFEC, 0x39: 0xFFE5, 0x4C: 0xFF8D,
        ]
        for (code, keysym) in expected { #expect(Keysym.macSpecial(keyCode: code) == keysym, "kVK \(code)") }
        #expect(Keysym.macSpecial(keyCode: 0x00) == nil) // "a" is printable
        #expect(Keysym.macUSLayout(keyCode: 0x00) == 0x61)
        #expect(Keysym.macUSLayout(keyCode: 0x08) == 0x63)
        #expect(Keysym.macUSLayout(keyCode: 0x1D) == 0x30)
        #expect(Keysym.macModifierDeviceMask(keyCode: 0x38) == 0x2)
        #expect(Keysym.macModifierDeviceMask(keyCode: 0x3C) == 0x4)
    }

    @Test("iOS HID usages")
    func hidTable() {
        let expected: [Int: UInt32] = [
            0x28: 0xFF0D, 0x29: 0xFF1B, 0x2A: 0xFF08, 0x2B: 0xFF09, 0x2C: 0x20, 0x3A: 0xFFBE, 0x45: 0xFFC9,
            0x49: 0xFF63, 0x4A: 0xFF50, 0x4B: 0xFF55, 0x4C: 0xFFFF, 0x4D: 0xFF57, 0x4E: 0xFF56, 0x4F: 0xFF53,
            0x50: 0xFF51, 0x51: 0xFF54, 0x52: 0xFF52, 0xE0: 0xFFE3, 0xE1: 0xFFE1, 0xE2: 0xFFE9, 0xE3: 0xFFEB,
            0xE4: 0xFFE4, 0xE5: 0xFFE2, 0xE6: 0xFFEA, 0xE7: 0xFFEC, 0x39: 0xFFE5,
        ]
        for (usage, keysym) in expected { #expect(Keysym.hidSpecial(usage: usage) == keysym, "HID \(usage)") }
        #expect(Keysym.hidUSLayout(usage: 0x04) == 0x61)
        #expect(Keysym.hidUSLayout(usage: 0x1D) == 0x7A)
        #expect(Keysym.hidUSLayout(usage: 0x1E) == 0x31)
        #expect(Keysym.hidUSLayout(usage: 0x27) == 0x30)
        #expect(Keysym.hidUSLayout(usage: 0x38) == 0x2F)
    }

    @Test("Hardware key resolution: layout characters, shortcuts, Option-composed, dead keys")
    func resolver() {
        typealias R = HardwareKeyResolver
        // Czech layout "ě" on the 2 key
        #expect(R.resolve(code: 0x13, table: .mac, characters: "ě", charactersIgnoringModifiers: "ě", modifiers: [])
                == .keysym(0x0100_011B))
        // Shift+a → "A"
        #expect(R.resolve(code: 0x00, table: .mac, characters: "A", charactersIgnoringModifiers: "A", modifiers: .shift)
                == .keysym(0x41))
        // Ctrl+C: the control character is replaced by the unmodified character
        #expect(R.resolve(code: 0x08, table: .mac, characters: "\u{03}", charactersIgnoringModifiers: "c",
                          modifiers: .control) == .keysym(0x63))
        // Cmd+W → "w" (Super is held separately)
        #expect(R.resolve(code: 0x0D, table: .mac, characters: "w", charactersIgnoringModifiers: "w",
                          modifiers: .command) == .keysym(0x77))
        // Option-composed "@" (Czech Mac layout) → typed without Alt
        #expect(R.resolve(code: 0x09, table: .mac, characters: "@", charactersIgnoringModifiers: "é",
                          modifiers: .option) == .composed(0x40))
        // Dead key: no character, no shortcut → let the platform handle it
        #expect(R.resolve(code: 0x2A, table: .mac, characters: "", charactersIgnoringModifiers: "", modifiers: [])
                == .unmapped)
        // Ctrl + key without character falls back to the US position
        #expect(R.resolve(code: 0x08, table: .mac, characters: "", charactersIgnoringModifiers: "", modifiers: .control)
                == .keysym(0x63))
        // Special keys win over characters
        #expect(R.resolve(code: 0x7E, table: .mac, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                          modifiers: []) == .keysym(Keysym.up))
        #expect(R.resolve(code: 0x2A, table: .hid, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}",
                          modifiers: []) == .keysym(Keysym.backSpace))
        #expect(R.resolve(code: 0x04, table: .hid, characters: "a", charactersIgnoringModifiers: "a", modifiers: [])
                == .keysym(0x61))
    }

    @Test("Key-up releases exactly what key-down pressed; composed and tap-only keys; release all")
    func tracker() {
        var keys = PressedKeyTracker()
        var sent: [(UInt32, Bool)] = []
        let send: (UInt32, Bool) -> Void = { sent.append(($0, $1)) }
        var results: [Bool] = []
        results.append(keys.keyDown(code: 0x3A, resolution: .keysym(Keysym.altL), send: send))
        results.append(keys.keyDown(code: 0x00, resolution: .keysym(0x61), send: send))
        // modifiers changed meanwhile: key-up still releases "a"
        results.append(keys.keyUp(code: 0x00, send: send))
        // composed: Alt is lifted around the character
        results.append(keys.keyDown(code: 0x09, resolution: .composed(0x40), send: send))
        results.append(keys.keyUp(code: 0x09, send: send)) // tap already complete: nothing sent
        results.append(keys.keyDown(code: 0x0D, resolution: .keysym(0x77), tapOnly: true, send: send))
        results.append(keys.keyDown(code: 0x2A, resolution: .unmapped, send: send))
        results.append(keys.keyUp(code: 0x55, send: send))
        #expect(results == [true, true, true, true, true, true, false, false])
        keys.releaseAll(send: send)
        let expected: [(UInt32, Bool)] = [
            (Keysym.altL, true), (0x61, true), (0x61, false),
            (Keysym.altL, false), (0x40, true), (0x40, false), (Keysym.altL, true),
            (0x77, true), (0x77, false),
            (Keysym.altL, false),
        ]
        #expect(sent.map(\.0) == expected.map(\.0))
        #expect(sent.map(\.1) == expected.map(\.1))
        #expect(keys.isEmpty)
    }
}

@Suite("Pointer coordinate mapping")
struct GeometryTests {
    @Test("Aspect fit with horizontal bars (wide view)")
    func pillarbox() throws {
        let g = DesktopGeometry(framebufferSize: CGSize(width: 1280, height: 800), viewSize: CGSize(width: 1600, height: 800))
        #expect(g.fitScale == 1)
        #expect(g.displayRect == CGRect(x: 160, y: 0, width: 1280, height: 800))
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 160, y: 0)) == FramebufferPoint(x: 0, y: 0))
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 1439.9, y: 799.9)) == FramebufferPoint(x: 1279, y: 799))
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 1440, y: 800)) == FramebufferPoint(x: 1279, y: 799))
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 100, y: 400)) == nil)
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 100, y: 400), clampToEdges: true)
                == FramebufferPoint(x: 0, y: 400))
    }

    @Test("Aspect fit with vertical bars (portrait phone), fractional scale")
    func letterbox() {
        let g = DesktopGeometry(framebufferSize: CGSize(width: 1280, height: 800), viewSize: CGSize(width: 390, height: 844))
        let s = 390.0 / 1280.0
        #expect(abs(g.fitScale - s) < 1e-9)
        let rect = g.displayRect
        #expect(abs(rect.minY - (844 - 800 * s) / 2) < 1e-9)
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 195, y: 422)) == FramebufferPoint(x: 640, y: 400))
        #expect(g.framebufferPoint(forViewPoint: CGPoint(x: 10, y: 10)) == nil)
        // round trip through every 97th pixel
        for x in stride(from: 0, to: 1280, by: 97) {
            for y in stride(from: 0, to: 800, by: 97) {
                let p = FramebufferPoint(x: x, y: y)
                #expect(g.framebufferPoint(forViewPoint: g.viewPoint(for: p)) == p)
            }
        }
    }

    @Test("Downscaled and upscaled fits round-trip exactly")
    func roundTrips() {
        for view in [CGSize(width: 640, height: 400), CGSize(width: 2560, height: 1600), CGSize(width: 1000, height: 333),
                     CGSize(width: 333, height: 1000)] {
            let g = DesktopGeometry(framebufferSize: CGSize(width: 1280, height: 800), viewSize: view)
            for p in [FramebufferPoint(x: 0, y: 0), FramebufferPoint(x: 1279, y: 799), FramebufferPoint(x: 640, y: 1),
                      FramebufferPoint(x: 3, y: 798)] {
                #expect(g.framebufferPoint(forViewPoint: g.viewPoint(for: p)) == p, "view \(view) point \(p)")
            }
        }
    }

    @Test("Zoomed / panned viewport (scroll view) mapping")
    func zoomed() {
        let fb = CGSize(width: 1280, height: 800)
        // 3× zoom, scrolled to (600, 300): the viewport's top-left is pixel (200, 100)
        #expect(DesktopGeometry.framebufferPoint(forViewportPoint: .zero, zoomScale: 3,
                                                 contentOffset: CGPoint(x: 600, y: 300), framebufferSize: fb)
                == FramebufferPoint(x: 200, y: 100))
        #expect(DesktopGeometry.framebufferPoint(forViewportPoint: CGPoint(x: 31, y: 14), zoomScale: 3,
                                                 contentOffset: CGPoint(x: 600, y: 300), framebufferSize: fb)
                == FramebufferPoint(x: 210, y: 104))
        // zoomed out and centred with negative offsets (content inset)
        #expect(DesktopGeometry.framebufferPoint(forViewportPoint: CGPoint(x: 50, y: 100), zoomScale: 0.25,
                                                 contentOffset: CGPoint(x: -50, y: -100), framebufferSize: fb)
                == FramebufferPoint(x: 0, y: 0))
        #expect(DesktopGeometry.framebufferPoint(forViewportPoint: CGPoint(x: 10, y: 10), zoomScale: 0.25,
                                                 contentOffset: CGPoint(x: -50, y: -100), framebufferSize: fb) == nil)
        #expect(DesktopGeometry.framebufferPoint(forViewportPoint: CGPoint(x: 10, y: 10), zoomScale: 0.25,
                                                 contentOffset: CGPoint(x: -50, y: -100), framebufferSize: fb,
                                                 clampToEdges: true) == FramebufferPoint(x: 0, y: 0))
        // content view in its own coordinates (UIScrollView zoom view)
        #expect(DesktopGeometry.framebufferPoint(forContentPoint: CGPoint(x: 639.5, y: 0.2), contentSize: fb,
                                                 framebufferSize: fb) == FramebufferPoint(x: 639, y: 0))
        #expect(DesktopGeometry.framebufferPoint(forContentPoint: CGPoint(x: 5000, y: -3), contentSize: fb,
                                                 framebufferSize: fb) == FramebufferPoint(x: 1279, y: 0))
    }

    @Test("Degenerate sizes never produce points")
    func degenerate() {
        #expect(DesktopGeometry(framebufferSize: .zero, viewSize: CGSize(width: 10, height: 10))
            .framebufferPoint(forViewPoint: CGPoint(x: 5, y: 5)) == nil)
        #expect(DesktopGeometry(framebufferSize: CGSize(width: 10, height: 10), viewSize: .zero)
            .framebufferPoint(forViewPoint: CGPoint(x: 5, y: 5)) == nil)
        #expect(DesktopGeometry(framebufferSize: CGSize(width: 10, height: 10), viewSize: CGSize(width: 10, height: 10))
            .framebufferPoint(forViewPoint: CGPoint(x: CGFloat.nan, y: 5)) == nil)
        #expect(DesktopGeometry.framebufferPoint(forViewportPoint: .zero, zoomScale: 0, contentOffset: .zero,
                                                 framebufferSize: CGSize(width: 10, height: 10)) == nil)
    }
}

@Suite("Input channel")
struct InputQueueTests {
    @Test("Disabled input never reaches the server; enabled input arrives in order")
    func gating() async throws {
        let h = try await Harness.start()
        let server = h.server
        h.client.input.pointer(x: 1, y: 2, buttons: .left)
        h.client.input.key(0x61, down: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await server.inputMessages.isEmpty)

        h.client.input.setEnabled(true)
        h.client.input.pointer(x: 10, y: 20, buttons: [])
        h.client.input.pointer(x: 11, y: 21, buttons: [])  // coalesced with the previous move
        h.client.input.pointer(x: 11, y: 21, buttons: .left)
        h.client.input.key(0x61, down: true)
        h.client.input.key(0x61, down: false)
        h.client.input.pointer(x: 11, y: 21, buttons: [])
        let expected: [ClientMessage] = [.pointer(buttons: 0, x: 11, y: 21), .pointer(buttons: 1, x: 11, y: 21),
                                         .key(keysym: 0x61, down: true), .key(keysym: 0x61, down: false),
                                         .pointer(buttons: 0, x: 11, y: 21)]
        #expect(await eventually { await server.inputMessages.count >= expected.count })
        let received = await server.inputMessages
        // the two moves may or may not coalesce depending on timing; the rest is strictly ordered
        #expect(Array(received.suffix(expected.count)) == expected)
        #expect(received.allSatisfy { $0 != .pointer(buttons: 1, x: 1, y: 2) })

        h.client.input.setEnabled(false)
        h.client.input.key(0x62, down: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await server.inputMessages.count == received.count)
        h.stop()
    }

    @Test("releaseAll lifts held keys and buttons")
    func releaseAll() async throws {
        let h = try await Harness.start()
        let server = h.server
        let input = h.client.input
        input.setEnabled(true)
        input.key(Keysym.controlL, down: true)
        input.key(0x63, down: true)
        input.pointer(x: 5, y: 5, buttons: [.left, .right])
        input.releaseAll()
        #expect(await eventually { await server.inputMessages.count >= 6 })
        let tail = Array(await server.inputMessages.suffix(3))
        #expect(tail.contains(.key(keysym: Keysym.controlL, down: false)))
        #expect(tail.contains(.key(keysym: 0x63, down: false)))
        #expect(tail.last == .pointer(buttons: 0, x: 5, y: 5))
        #expect(input.heldButtons.isEmpty)
        h.stop()
    }

    @Test("A closed connection drops input")
    func closed() async throws {
        let h = try await Harness.start()
        h.client.input.setEnabled(true)
        h.stop()
        _ = try? await h.run.value
        #expect(!h.client.input.isEnabled)
        h.client.input.key(0x61, down: true)
        #expect(h.client.input.isIdle)
    }
}
