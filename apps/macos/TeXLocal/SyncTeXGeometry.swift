import CoreGraphics

/// SyncTeX uses top-left PDF points; PDFKit uses bottom-left page-box points.
enum SyncTeXGeometry {
    /// A box SyncTeX gives no size has a line's height and a word's width.
    static func highlightRect(_ loc: ForwardLoc, pageBounds: CGRect) -> CGRect {
        CGRect(x: pageBounds.minX + (loc.h ?? 0), y: pageBounds.maxY - (loc.v ?? 0),
               width: max(24, CGFloat(loc.width ?? 0)), height: CGFloat(loc.height ?? 12))
            .insetBy(dx: -2, dy: -2)
    }

    static func synctexPoint(_ point: CGPoint, pageBounds: CGRect) -> CGPoint {
        CGPoint(x: point.x - pageBounds.minX, y: pageBounds.maxY - point.y)
    }
}
