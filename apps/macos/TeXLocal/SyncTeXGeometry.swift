import CoreGraphics

/// SyncTeX uses top-left PDF points; PDFKit uses bottom-left page-box points.
/// Their axes meet only here.
enum SyncTeXGeometry {
    /// Flash dimensions in PDF page points.
    private static let lineHeight: CGFloat = 12
    private static let minimumWidth: CGFloat = 24
    private static let margin: CGFloat = 2

    /// The page rectangle to flash for a forward-search result.
    static func highlightRect(_ loc: ForwardLoc, pageBounds: CGRect) -> CGRect {
        let height = loc.height ?? lineHeight
        let width = max(minimumWidth, loc.width ?? 0)
        let x = pageBounds.minX + (loc.h ?? 0)
        let baseline = pageBounds.maxY - (loc.v ?? 0)
        return CGRect(x: x, y: baseline, width: width, height: height).insetBy(dx: -margin, dy: -margin)
    }

    /// A point in PDFKit page space as SyncTeX's (x, y) for an inverse search.
    static func synctexPoint(_ point: CGPoint, pageBounds: CGRect) -> CGPoint {
        CGPoint(x: point.x - pageBounds.minX, y: pageBounds.maxY - point.y)
    }
}
