import CoreGraphics

/// SyncTeX uses top-left PDF points; PDFKit uses bottom-left page-box points.
enum SyncTeXGeometry {
    private static let lineHeight: CGFloat = 12
    private static let minimumWidth: CGFloat = 24
    private static let margin: CGFloat = 2

    static func highlightRect(_ loc: ForwardLoc, pageBounds: CGRect) -> CGRect {
        let baseline = pageBounds.maxY - (loc.v ?? 0)
        return CGRect(x: pageBounds.minX + (loc.h ?? 0), y: baseline, width: max(minimumWidth, loc.width ?? 0), height: loc.height ?? lineHeight)
            .insetBy(dx: -margin, dy: -margin)
    }

    static func synctexPoint(_ point: CGPoint, pageBounds: CGRect) -> CGPoint {
        CGPoint(x: point.x - pageBounds.minX, y: pageBounds.maxY - point.y)
    }
}
