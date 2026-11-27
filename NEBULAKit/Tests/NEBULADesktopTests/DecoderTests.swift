import Foundation
@testable import NEBULADesktop
import Testing

@Suite("Rectangle decoders")
struct DecoderTests {
    @Test("Raw rectangle lands at the right place in BGRX")
    func raw() async throws {
        let h = try await Harness.start()
        let colors: [UInt32] = [0xFF0000, 0x00FF00, 0x0000FF, 0x123456, 0xABCDEF, 0x000000, 0xFFFFFF, 0x7F7F7F]
        try await h.apply([Wire.raw(2, 3, 4, 2, colors)])
        #expect(await h.client.pixel(x: 2, y: 3) == 0xFFFF_0000)
        #expect(await h.client.pixel(x: 5, y: 3) == 0xFF12_3456)
        #expect(await h.client.pixel(x: 3, y: 4) == 0xFF00_0000)
        #expect(await h.client.pixel(x: 5, y: 4) == 0xFF7F_7F7F)
        #expect(await h.client.pixel(x: 1, y: 3) == 0xFF00_0000) // untouched
        h.stop()
    }

    @Test("Frames reach the mailbox as BGRX CGImages")
    func mailboxFrame() async throws {
        let h = try await Harness.start(width: 8, height: 4)
        try await h.apply([Wire.tightFill(0, 0, 8, 4, 0x204060)])
        let mailbox = h.mailbox
        #expect(await eventually { mailbox.latestFrame != nil })
        let frame = try #require(mailbox.takeFrame(newerThan: 0)?.frame)
        #expect(frame.width == 8 && frame.height == 4)
        let data = try #require(frame.image.dataProvider?.data as Data?)
        #expect(Array(data.prefix(4)) == [0x60, 0x40, 0x20, 0xFF]) // B G R X
        #expect(frame.image.bitmapInfo.contains(.byteOrder32Little))
        h.stop()
    }

    @Test("CopyRect, including overlapping source and destination")
    func copyRect() async throws {
        let h = try await Harness.start()
        try await h.apply([Wire.tightFill(0, 0, 4, 4, 0xAA0000), Wire.tightFill(4, 0, 4, 4, 0x00BB00)])
        try await h.apply([Wire.copyRect(10, 10, 8, 4, from: 0, 0)])
        #expect(await h.client.pixel(x: 10, y: 10) == 0xFFAA_0000)
        #expect(await h.client.pixel(x: 17, y: 13) == 0xFF00_BB00)
        // overlap: shift the 8×4 block one pixel right
        try await h.apply([Wire.copyRect(11, 10, 8, 4, from: 10, 10)])
        #expect(await h.client.pixel(x: 11, y: 10) == 0xFFAA_0000)
        #expect(await h.client.pixel(x: 14, y: 12) == 0xFFAA_0000)
        #expect(await h.client.pixel(x: 15, y: 12) == 0xFF00_BB00)
        #expect(await h.client.pixel(x: 18, y: 13) == 0xFF00_BB00)
        h.stop()
    }

    @Test("Tight fill")
    func tightFill() async throws {
        let h = try await Harness.start()
        try await h.apply([Wire.tightFill(1, 1, 10, 5, 0x10_20_30, reset: 0x0F)])
        #expect(await h.client.pixel(x: 1, y: 1) == 0xFF10_2030)
        #expect(await h.client.pixel(x: 10, y: 5) == 0xFF10_2030)
        #expect(await h.client.pixel(x: 11, y: 5) == 0xFF00_0000)
        h.stop()
    }

    @Test("Tight JPEG decoded with ImageIO, upright")
    func tightJPEG() async throws {
        let h = try await Harness.start()
        let jpeg = makeJPEG(width: 16, height: 16, top: 0xE01010, bottom: 0x1020E0)
        try await h.apply([Wire.tightJPEG(8, 4, 16, 16, jpeg)])
        #expect(close(await h.client.pixel(x: 16, y: 6), to: 0xE01010, tolerance: 40))
        #expect(close(await h.client.pixel(x: 16, y: 17), to: 0x1020E0, tolerance: 40))
        #expect(await h.client.pixel(x: 7, y: 6) == 0xFF00_0000)
        h.stop()
    }

    @Test("Tight JPEG with mismatching dimensions is a protocol error")
    func tightJPEGMismatch() async throws {
        let h = try await Harness.start()
        let jpeg = makeJPEG(width: 8, height: 8, top: 0xFFFFFF, bottom: 0)
        let error = await h.expectFailure(Wire.update([Wire.tightJPEG(0, 0, 16, 16, jpeg)]))
        #expect(error is RFBError)
    }

    @Test("Tight basic: copy filter, uncompressed (<12 bytes) and zlib")
    func tightBasicCopy() async throws {
        let h = try await Harness.start()
        let deflater = Deflater()
        // 3 pixels = 9 bytes < 12 → sent raw, no length
        let small: [UInt32] = [0x010203, 0x040506, 0x070809]
        try await h.apply([Wire.tightBasic(0, 0, 3, 1, stream: 0, filter: nil, data: small.flatMap(Wire.rgb),
                                           deflater: nil)])
        #expect(await h.client.pixel(x: 2, y: 0) == 0xFF07_0809)
        // 8×4 = 96 bytes → zlib on stream 2 with an explicit copy filter
        let colors = (0..<32).map { UInt32($0 * 0x070503) & 0xFFFFFF }
        try await h.apply([Wire.tightBasic(10, 10, 8, 4, stream: 2, filter: 0, data: colors.flatMap(Wire.rgb),
                                           deflater: deflater)])
        for i in [0, 7, 13, 31] {
            #expect(await h.client.pixel(x: 10 + i % 8, y: 10 + i / 8) == 0xFF00_0000 | colors[i])
        }
        h.stop()
    }

    @Test("Tight palette filter: 2 colours (1 bpp) and 5 colours (8 bpp)")
    func tightPalette() async throws {
        let h = try await Harness.start()
        let deflater = Deflater()
        // 10×3, 2 colours: rows of 2 bytes, MSB first
        let mono: [UInt8] = [0b1010_1010, 0b1100_0000, 0b0000_0000, 0b0100_0000, 0b1111_1111, 0b1100_0000]
        try await h.apply([Wire.tightBasic(0, 0, 10, 3, stream: 1, filter: 1,
                                           filterParameters: [1] + Wire.rgb(0x000000) + Wire.rgb(0xFFFFFF),
                                           data: mono, deflater: deflater)])
        #expect(await h.client.pixel(x: 0, y: 0) == 0xFFFF_FFFF)
        #expect(await h.client.pixel(x: 1, y: 0) == 0xFF00_0000)
        #expect(await h.client.pixel(x: 8, y: 0) == 0xFFFF_FFFF)
        #expect(await h.client.pixel(x: 9, y: 0) == 0xFFFF_FFFF)
        #expect(await h.client.pixel(x: 9, y: 1) == 0xFFFF_FFFF)
        #expect(await h.client.pixel(x: 8, y: 1) == 0xFF00_0000)
        #expect(await h.client.pixel(x: 5, y: 2) == 0xFFFF_FFFF)

        let palette: [UInt32] = [0x111111, 0x222222, 0x333333, 0x444444, 0x555555]
        let indices: [UInt8] = (0..<24).map { UInt8($0 % 5) }
        try await h.apply([Wire.tightBasic(20, 20, 6, 4, stream: 3, filter: 1,
                                           filterParameters: [UInt8(palette.count - 1)] + palette.flatMap(Wire.rgb),
                                           data: indices, deflater: Deflater())])
        for i in 0..<24 {
            #expect(await h.client.pixel(x: 20 + i % 6, y: 20 + i / 6) == 0xFF00_0000 | palette[i % 5])
        }
        h.stop()
    }

    @Test("Tight gradient filter reproduces the original pixels")
    func tightGradient() async throws {
        let h = try await Harness.start()
        let w = 9, hgt = 5
        let colors: [UInt32] = (0..<(w * hgt)).map { i in
            let x = i % w, y = i / w
            return UInt32((x * 28) & 0xFF) << 16 | UInt32((y * 50) & 0xFF) << 8 | UInt32((x * y * 7 + 200) & 0xFF)
        }
        let data = Wire.gradientEncode(colors, width: w, height: hgt)
        try await h.apply([Wire.tightBasic(3, 2, w, hgt, stream: 0, filter: 2, data: data, deflater: Deflater())])
        for i in 0..<(w * hgt) {
            #expect(await h.client.pixel(x: 3 + i % w, y: 2 + i / w) == 0xFF00_0000 | colors[i])
        }
        h.stop()
    }

    @Test("zlib stream state persists across rectangles and honours the reset bits")
    func zlibContinuity() async throws {
        let h = try await Harness.start()
        var deflater = Deflater()
        let colors = (0..<64).map { UInt32($0 * 0x030201) & 0xFFFFFF }
        let rgb = colors.flatMap(Wire.rgb)
        // Same data twice on stream 1: the second payload is mostly back-references into the first.
        let first = Wire.tightBasic(0, 0, 8, 8, stream: 1, filter: nil, data: rgb, deflater: deflater)
        let second = Wire.tightBasic(8, 0, 8, 8, stream: 1, filter: nil, data: rgb, deflater: deflater)
        #expect(second.count < first.count)
        try await h.apply([first, second])
        #expect(await h.client.pixel(x: 15, y: 7) == 0xFF00_0000 | colors[63])
        #expect(await h.client.pixel(x: 7, y: 7) == 0xFF00_0000 | colors[63])
        // Another update on the same stream (dictionary carried over).
        try await h.apply([Wire.tightBasic(16, 0, 8, 8, stream: 1, filter: nil, data: rgb, deflater: deflater)])
        #expect(await h.client.pixel(x: 16, y: 0) == 0xFF00_0000 | colors[0])
        // The server resets stream 1 (fresh deflater) and sets reset bit 1.
        deflater = Deflater()
        try await h.apply([Wire.tightBasic(24, 0, 8, 8, stream: 1, filter: nil, data: rgb, deflater: deflater,
                                           reset: 0b0010)])
        #expect(await h.client.pixel(x: 31, y: 7) == 0xFF00_0000 | colors[63])
        h.stop()
    }

    @Test("A reset stream without the reset bit fails cleanly (no crash)")
    func zlibDesync() async throws {
        let h = try await Harness.start()
        let rgb = (0..<64).flatMap { Wire.rgb(UInt32($0) * 0x010101) }
        try await h.apply([Wire.tightBasic(0, 0, 8, 8, stream: 0, filter: nil, data: rgb, deflater: Deflater())])
        let error = await h.expectFailure(Wire.update([
            Wire.tightBasic(0, 0, 8, 8, stream: 0, filter: nil, data: rgb, deflater: Deflater()),
        ]))
        #expect(error is RFBError)
    }

    @Test("ZRLE: solid and raw tiles across a tile boundary, persistent stream")
    func zrleSolidAndRaw() async throws {
        let h = try await Harness.start(width: 128, height: 64)
        let deflater = Deflater()
        // 80×3: tile 1 is 64×3 (solid), tile 2 is 16×3 (raw)
        let rawColors = (0..<48).map { UInt32($0 * 0x050301) & 0xFFFFFF }
        let tiles: [UInt8] = [1] + Wire.cpixel(0xCC8844) + [0] + rawColors.flatMap(Wire.cpixel)
        try await h.apply([Wire.zrle(4, 5, 80, 3, tiles: tiles, deflater: deflater)])
        #expect(await h.client.pixel(x: 4, y: 5) == 0xFFCC_8844)
        #expect(await h.client.pixel(x: 67, y: 7) == 0xFFCC_8844)
        #expect(await h.client.pixel(x: 68, y: 5) == 0xFF00_0000 | rawColors[0])
        #expect(await h.client.pixel(x: 83, y: 7) == 0xFF00_0000 | rawColors[47])
        // second rectangle on the same zlib stream
        try await h.apply([Wire.zrle(0, 40, 10, 2, tiles: [1] + Wire.cpixel(0x010203), deflater: deflater)])
        #expect(await h.client.pixel(x: 9, y: 41) == 0xFF01_0203)
        h.stop()
    }

    @Test("ZRLE: packed palette, plain RLE and palette RLE tiles")
    func zrlePaletteAndRLE() async throws {
        let h = try await Harness.start(width: 64, height: 64)
        let deflater = Deflater()
        // packed palette, 3 colours → 2 bits per pixel; 4×2 tile: rows [0,1,2,1] and [2,2,0,0]
        let packed: [UInt8] = [3] + Wire.cpixel(0x100000) + Wire.cpixel(0x002000) + Wire.cpixel(0x000030)
            + [0b00_01_10_01, 0b10_10_00_00]
        try await h.apply([Wire.zrle(0, 0, 4, 2, tiles: packed, deflater: deflater)])
        #expect(await h.client.pixel(x: 1, y: 0) == 0xFF00_2000)
        #expect(await h.client.pixel(x: 2, y: 0) == 0xFF00_0030)
        #expect(await h.client.pixel(x: 0, y: 1) == 0xFF00_0030)
        #expect(await h.client.pixel(x: 3, y: 1) == 0xFF10_0000)
        // plain RLE on a 5×2 tile: 7 × A then 3 × B (run lengths are value − 1)
        let rle: [UInt8] = [128] + Wire.cpixel(0xAAAAAA) + [6] + Wire.cpixel(0xBBBBBB) + [2]
        try await h.apply([Wire.zrle(10, 10, 5, 2, tiles: rle, deflater: deflater)])
        #expect(await h.client.pixel(x: 14, y: 10) == 0xFFAA_AAAA)
        #expect(await h.client.pixel(x: 11, y: 11) == 0xFFAA_AAAA)
        #expect(await h.client.pixel(x: 12, y: 11) == 0xFFBB_BBBB)
        #expect(await h.client.pixel(x: 14, y: 11) == 0xFFBB_BBBB)
        // palette RLE (2 colours) on a 300-pixel row (20×15): long run with a 255 continuation byte
        let paletteRLE: [UInt8] = [130] + Wire.cpixel(0x0A0B0C) + Wire.cpixel(0xC0B0A0)
            + [0x01] + [0x80, 255, 42] + [0x81, 0]
        // 1 pixel of colour 1, then 1 + 255 + 42 = 298 of colour 0, then 1 of colour 1 → 300
        try await h.apply([Wire.zrle(20, 20, 20, 15, tiles: paletteRLE, deflater: deflater)])
        #expect(await h.client.pixel(x: 20, y: 20) == 0xFFC0_B0A0)
        #expect(await h.client.pixel(x: 21, y: 20) == 0xFF0A_0B0C)
        #expect(await h.client.pixel(x: 38, y: 34) == 0xFF0A_0B0C)
        #expect(await h.client.pixel(x: 39, y: 34) == 0xFFC0_B0A0)
        h.stop()
    }

    @Test("DesktopSize and ExtendedDesktopSize resize and trigger a full refresh")
    func desktopResize() async throws {
        let h = try await Harness.start(width: 64, height: 48)
        let resized = Task { () -> (Int, Int)? in
            for await e in h.client.events { if case .desktopResized(let w, let hh) = e { return (w, hh) } }
            return nil
        }
        try await h.apply([Wire.header(0, 0, 100, 70, -223), Wire.tightFill(0, 0, 100, 70, 0x445566)])
        let size = await resized.value
        #expect(size?.0 == 100 && size?.1 == 70)
        #expect(await h.client.desktopSize?.width == 100)
        #expect(await h.client.pixel(x: 99, y: 69) == 0xFF44_5566)
        let server = h.server
        #expect(await eventually {
            await server.updateRequests.last == .updateRequest(incremental: false, x: 0, y: 0, width: 100, height: 70)
        })
        // ExtendedDesktopSize (reason 0, status 0, one screen)
        let screen: [UInt8] = Wire.u32(1) + Wire.u16(0) + Wire.u16(0) + Wire.u16(200) + Wire.u16(120) + Wire.u32(0)
        try await h.apply([Wire.header(0, 0, 200, 120, -308) + [1, 0, 0, 0] + screen])
        #expect(await h.client.desktopSize?.height == 120)
        // A failed status (answer to a SetDesktopSize) leaves the size alone.
        try await h.apply([Wire.header(1, 3, 300, 300, -308) + [0, 0, 0, 0]])
        #expect(await h.client.desktopSize?.width == 200)
        h.stop()
    }

    @Test("LastRect ends an update with an open rectangle count")
    func lastRect() async throws {
        let h = try await Harness.start()
        let before = await h.server.updateRequests.count
        try await h.apply([Wire.tightFill(0, 0, 4, 4, 0x0000FF), Wire.header(0, 0, 0, 0, -224)], count: 0xFFFF)
        #expect(await h.client.pixel(x: 3, y: 3) == 0xFF00_00FF)
        let server = h.server
        #expect(await eventually { await server.updateRequests.count > before })
        #expect(await server.updateRequests.last == .updateRequest(incremental: true, x: 0, y: 0, width: 64, height: 48))
        // still in sync: the next update decodes
        try await h.apply([Wire.tightFill(0, 0, 1, 1, 0x00FF00)])
        #expect(await h.client.pixel(x: 0, y: 0) == 0xFF00_FF00)
        h.stop()
    }

    @Test("Bell, colour map and the agent's clipboard (discarded) keep the stream in sync")
    func otherServerMessages() async throws {
        let h = try await Harness.start()
        let bell = Task { () -> Bool in
            for await e in h.client.events { if case .bell = e { return true } }
            return false
        }
        let cut = Array("secret clipboard".utf8)
        try await h.server.send([2] + [3, 0, 0, 0] + Wire.u32(UInt32(cut.count)) + cut + [1, 0] + Wire.u16(0)
                                + Wire.u16(1) + [0, 0, 0, 0, 0, 0])
        try await h.apply([Wire.tightFill(0, 0, 2, 2, 0x778899)])
        #expect(await h.client.pixel(x: 1, y: 1) == 0xFF77_8899)
        #expect(await bell.value)
        h.stop()
    }

    @Test("Pipelining: exactly one incremental request per decoded update")
    func pipelining() async throws {
        let h = try await Harness.start()
        let server = h.server
        try await h.apply([Wire.tightFill(0, 0, 1, 1, 0x010101)])
        #expect(await eventually { await server.updateRequests.count == 2 })
        try await h.apply([Wire.tightFill(0, 0, 1, 1, 0x020202)])
        #expect(await eventually { await server.updateRequests.count == 3 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await server.updateRequests.count == 3)
        #expect(await server.updateRequests.last == .updateRequest(incremental: true, x: 0, y: 0, width: 64, height: 48))
        h.stop()
    }

    @Test("Pause stops requests; resume asks for a full non-incremental update")
    func pauseResume() async throws {
        let h = try await Harness.start()
        let server = h.server
        try await h.apply([Wire.tightFill(0, 0, 1, 1, 0x010101)])
        #expect(await eventually { await server.updateRequests.count == 2 })
        try await h.client.setPaused(true)
        try await h.apply([Wire.tightFill(0, 0, 1, 1, 0x020202)]) // answers the outstanding request
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await server.updateRequests.count == 2)
        try await h.client.setPaused(false)
        #expect(await eventually { await server.updateRequests.count == 3 })
        #expect(await server.updateRequests.last == .updateRequest(incremental: false, x: 0, y: 0, width: 64, height: 48))
        // stale sequence numbers are ignored
        try await h.client.setPaused(true, sequence: 5)
        try await h.client.setPaused(false, sequence: 4)
        try await h.apply([Wire.tightFill(0, 0, 1, 1, 0x030303)])
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await server.updateRequests.count == 3)
        h.stop()
    }

    @Test("Image quality change re-sends SetEncodings and refreshes")
    func qualityChange() async throws {
        let h = try await Harness.start()
        try await h.client.setJPEGQuality(3)
        let server = h.server
        #expect(await eventually {
            await server.messages.contains(.setEncodings(expectedEncodings(quality: 3)))
        })
        h.stop()
    }
}

@Suite("Malformed streams")
struct MalformedStreamTests {
    private func failure(_ bytes: [UInt8], width: Int = 64, height: Int = 48) async throws -> (any Error)? {
        let h = try await Harness.start(width: width, height: height)
        return await h.expectFailure(bytes)
    }

    @Test("Rectangle outside the framebuffer")
    func rectOutOfBounds() async throws {
        let e = try await failure(Wire.update([Wire.tightFill(60, 40, 10, 10, 0)]))
        #expect(e as? RFBError == .rectOutOfBounds(x: 60, y: 40, width: 10, height: 10))
        let raw = try await failure(Wire.update([Wire.header(65535, 65535, 65535, 65535, 0)]))
        #expect(raw is RFBError)
    }

    @Test("CopyRect source outside the framebuffer")
    func copyRectSource() async throws {
        let e = try await failure(Wire.update([Wire.copyRect(0, 0, 10, 10, from: 60, 0)]))
        #expect(e as? RFBError == .rectOutOfBounds(x: 60, y: 0, width: 10, height: 10))
    }

    @Test("Truncated stream ends as a closed connection, not a crash")
    func truncated() async throws {
        let h = try await Harness.start()
        try await h.server.send(Array(Wire.update([Wire.raw(0, 0, 8, 8, Array(repeating: 0xFFFFFF, count: 64))])
            .dropLast(17)))
        h.server.transport.close()
        do {
            try await h.run.value
            Issue.record("expected failure")
        } catch {
            #expect(error is RFBTransportError)
        }
    }

    @Test("Tight palette index beyond the palette")
    func tightPaletteOverflow() async throws {
        let indices: [UInt8] = [0, 1, 2, 7] + Array(repeating: 0, count: 12)
        let e = try await failure(Wire.update([Wire.tightBasic(0, 0, 4, 4, stream: 0, filter: 1,
                                                               filterParameters: [2] + Array(repeating: 0, count: 9),
                                                               data: indices, deflater: Deflater())]))
        #expect(e as? RFBError == .paletteIndexOutOfRange)
    }

    @Test("ZRLE packed palette index beyond the palette")
    func zrlePaletteOverflow() async throws {
        let tile: [UInt8] = [3] + Array(repeating: 0, count: 9) + [0b11_00_00_00]
        let e = try await failure(Wire.update([Wire.zrle(0, 0, 4, 1, tiles: tile, deflater: Deflater())]))
        #expect(e as? RFBError == .paletteIndexOutOfRange)
    }

    @Test("ZRLE run longer than the tile, unknown sub-encoding, short tile data")
    func zrleGarbage() async throws {
        let longRun: [UInt8] = [128] + [1, 2, 3] + [255, 255, 0]
        #expect(try await failure(Wire.update([Wire.zrle(0, 0, 8, 8, tiles: longRun, deflater: Deflater())])) is RFBError)
        #expect(try await failure(Wire.update([Wire.zrle(0, 0, 8, 8, tiles: [77], deflater: Deflater())])) is RFBError)
        #expect(try await failure(Wire.update([Wire.zrle(0, 0, 8, 8, tiles: [0, 1, 2, 3], deflater: Deflater())]))
                    is RFBError)
    }

    @Test("Oversized length fields are refused before allocating")
    func oversizedLengths() async throws {
        let zrle = try await failure(Wire.update([Wire.header(0, 0, 8, 8, 16) + Wire.u32(0x7FFF_FFFF)]))
        #expect(zrle as? RFBError == .messageTooLarge(0x7FFF_FFFF))
        let cut = try await failure([3, 0, 0, 0] + Wire.u32(0x4000_0000))
        #expect(cut as? RFBError == .messageTooLarge(0x4000_0000))
    }

    @Test("Garbage zlib payload")
    func garbageZlib() async throws {
        let rect = Wire.header(0, 0, 8, 8, 7) + [0x00] + Wire.compact(20) + Array(repeating: 0xAB, count: 20)
        #expect(try await failure(Wire.update([rect])) is RFBError)
    }

    @Test("Unknown message type, unknown encoding, undefined Tight compression")
    func unknowns() async throws {
        #expect(try await failure([42]) as? RFBError == .protocolViolation("unknown server message type 42"))
        #expect(try await failure(Wire.update([Wire.header(0, 0, 1, 1, 5)])) as? RFBError == .unsupportedEncoding(5))
        #expect(try await failure(Wire.update([Wire.header(0, 0, 1, 1, 7) + [0xA0]])) is RFBError)
        #expect(try await failure(Wire.update([Wire.header(0, 0, 1, 1, 7) + [0x40, 9]])) is RFBError)
    }

    @Test("Resize beyond the cap is refused")
    func resizeTooLarge() async throws {
        let e = try await failure(Wire.update([Wire.header(0, 0, 9000, 100, -223)]))
        #expect(e as? RFBError == .invalidFramebufferSize(width: 9000, height: 100))
    }

    @Test("Random garbage never crashes the decoder")
    func fuzz() async throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let h = try await Harness.start(width: 32, height: 32)
            let encodings: [Int32] = [0, 1, 7, 16, -223, -224, -308]
            var bytes: [UInt8] = [0, 0, 0, 1]
            bytes += Wire.header(Int.random(in: 0..<40, using: &rng), Int.random(in: 0..<40, using: &rng),
                                 Int.random(in: 0..<40, using: &rng), Int.random(in: 0..<40, using: &rng),
                                 encodings.randomElement(using: &rng)!)
            bytes += (0..<Int.random(in: 0..<400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            try await h.server.send(bytes)
            try? await Task.sleep(for: .milliseconds(5))
            h.server.transport.close()
            _ = try? await h.run.value
        }
    }
}
