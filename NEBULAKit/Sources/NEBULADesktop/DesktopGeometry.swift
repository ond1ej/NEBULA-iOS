import CoreGraphics
import Foundation

/// A framebuffer pixel coordinate (what PointerEvent carries).
public struct FramebufferPoint: Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
    public var description: String { "(\(x), \(y))" }
}

/// Maps view coordinates to framebuffer pixels for an aspect-fit display (letterboxed and centred), optionally
/// zoomed and panned. All coordinates have a top-left origin.
public struct DesktopGeometry: Equatable, Sendable {
    /// Framebuffer size in pixels.
    public var framebufferSize: CGSize
    /// The view's size in points.
    public var viewSize: CGSize

    public init(framebufferSize: CGSize, viewSize: CGSize) {
        self.framebufferSize = framebufferSize
        self.viewSize = viewSize
    }

    private var isValid: Bool {
        framebufferSize.width >= 1 && framebufferSize.height >= 1 && viewSize.width > 0 && viewSize.height > 0
            && framebufferSize.width.isFinite && framebufferSize.height.isFinite
            && viewSize.width.isFinite && viewSize.height.isFinite
    }

    /// View points per framebuffer pixel at aspect fit.
    public var fitScale: CGFloat {
        guard isValid else { return 0 }
        return min(viewSize.width / framebufferSize.width, viewSize.height / framebufferSize.height)
    }

    /// Where the framebuffer is drawn (aspect fit, centred) in view coordinates.
    public var displayRect: CGRect {
        let s = fitScale
        let w = framebufferSize.width * s, h = framebufferSize.height * s
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// The pixel under a view point. Outside the image (the letterbox) returns nil, or the nearest edge pixel when
    /// `clampToEdges` (drags that leave the image keep tracking the edge).
    public func framebufferPoint(forViewPoint p: CGPoint, clampToEdges: Bool = false) -> FramebufferPoint? {
        let s = fitScale
        guard s > 0, p.x.isFinite, p.y.isFinite else { return nil }
        let r = displayRect
        if !clampToEdges, !(p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY) { return nil }
        return Self.pixel(x: (p.x - r.minX) / s, y: (p.y - r.minY) / s, framebufferSize: framebufferSize)
    }

    /// The view point at the centre of a framebuffer pixel.
    public func viewPoint(for p: FramebufferPoint) -> CGPoint {
        let s = fitScale
        let r = displayRect
        return CGPoint(x: r.minX + (CGFloat(p.x) + 0.5) * s, y: r.minY + (CGFloat(p.y) + 0.5) * s)
    }

    /// A point in a content view that shows the whole framebuffer scaled to `contentSize` (e.g. the zoomable view
    /// inside a scroll view, in its own unzoomed coordinates). Clamped to the framebuffer.
    public static func framebufferPoint(forContentPoint p: CGPoint, contentSize: CGSize,
                                        framebufferSize: CGSize) -> FramebufferPoint? {
        guard contentSize.width > 0, contentSize.height > 0, framebufferSize.width >= 1,
              framebufferSize.height >= 1, p.x.isFinite, p.y.isFinite else { return nil }
        return pixel(x: p.x * framebufferSize.width / contentSize.width,
                     y: p.y * framebufferSize.height / contentSize.height, framebufferSize: framebufferSize)
    }

    /// A point in a zoomed, panned viewport: content drawn at `zoomScale` points per pixel, whose visible top-left
    /// is `contentOffset` in zoomed content coordinates (negative when the content is centred by insets, as in a
    /// UIScrollView). Returns nil outside the content unless `clampToEdges`.
    public static func framebufferPoint(forViewportPoint p: CGPoint, zoomScale: CGFloat, contentOffset: CGPoint,
                                        framebufferSize: CGSize, clampToEdges: Bool = false) -> FramebufferPoint? {
        guard zoomScale > 0, zoomScale.isFinite, framebufferSize.width >= 1, framebufferSize.height >= 1,
              p.x.isFinite, p.y.isFinite, contentOffset.x.isFinite, contentOffset.y.isFinite else { return nil }
        let fx = (p.x + contentOffset.x) / zoomScale
        let fy = (p.y + contentOffset.y) / zoomScale
        if !clampToEdges,
           !(fx >= 0 && fy >= 0 && fx <= framebufferSize.width && fy <= framebufferSize.height) { return nil }
        return pixel(x: fx, y: fy, framebufferSize: framebufferSize)
    }

    private static func pixel(x: CGFloat, y: CGFloat, framebufferSize: CGSize) -> FramebufferPoint {
        let maxX = max(Int(framebufferSize.width) - 1, 0), maxY = max(Int(framebufferSize.height) - 1, 0)
        let px = x.isFinite ? Int(min(max(x.rounded(.down), 0), CGFloat(maxX))) : 0
        let py = y.isFinite ? Int(min(max(y.rounded(.down), 0), CGFloat(maxY))) : 0
        return FramebufferPoint(x: px, y: py)
    }
}
