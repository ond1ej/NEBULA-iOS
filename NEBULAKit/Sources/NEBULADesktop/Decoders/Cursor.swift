import CoreGraphics
import Foundation

/// The remote cursor shape (Cursor pseudo-encoding -239), only requested when
/// `RFBClient.Configuration.requestCursorShape` is on: the server then stops drawing the pointer into the
/// framebuffer and the viewer draws it locally (zero-latency pointer while in control on the Mac).
public struct RemoteCursor: @unchecked Sendable {
    // CGImage is immutable and thread-safe.
    public let image: CGImage
    public let hotspotX: Int
    public let hotspotY: Int
}

enum CursorDecoder {
    /// Cursors above this are rejected (X cursors are at most a few hundred pixels even on HiDPI).
    static let maximumDimension = 512

    static func payloadSize(width w: Int, height h: Int) -> Int {
        w * h * 4 + ((w + 7) / 8) * h
    }

    /// `payload` holds w×h BGRX pixels followed by a 1-bit mask (rows padded to whole bytes, MSB first).
    static func decode(_ payload: UnsafeRawBufferPointer, width w: Int, height h: Int, hotspotX: Int,
                       hotspotY: Int) -> RemoteCursor? {
        guard w > 0, h > 0, payload.count >= payloadSize(width: w, height: h) else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let maskStart = w * h * 4
        let maskRow = (w + 7) / 8
        for y in 0..<h {
            for x in 0..<w {
                let visible = (payload[maskStart + y * maskRow + (x >> 3)] >> (7 - UInt8(x & 7))) & 1 == 1
                guard visible else { continue }
                let s = (y * w + x) * 4
                // premultiplied BGRA (byteOrder32Little + premultipliedFirst), fully opaque where visible
                rgba[s] = payload[s]
                rgba[s + 1] = payload[s + 1]
                rgba[s + 2] = payload[s + 2]
                rgba[s + 3] = 255
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: Framebuffer.colorSpace, bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return RemoteCursor(image: image, hotspotX: min(max(hotspotX, 0), w - 1), hotspotY: min(max(hotspotY, 0), h - 1))
    }
}
