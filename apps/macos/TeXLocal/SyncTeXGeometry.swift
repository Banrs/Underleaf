import CoreGraphics

/// SyncTeX measures from a page's top-left corner in PDF points; PDFKit's page
/// space starts at the bottom-left of the page's box. These are the only two
/// places the axes meet.
enum SyncTeXGeometry {
    /// The page rectangle to flash for a forward-search result, padded like the
    /// browser version's highlight and never narrower than a word.
    static func highlightRect(_ loc: ForwardLoc, pageBounds: CGRect) -> CGRect {
        let height = loc.height ?? 12
        let width = max(24, loc.width ?? 0)
        let x = pageBounds.minX + (loc.h ?? 0)
        let baseline = pageBounds.maxY - (loc.v ?? 0)
        return CGRect(x: x - 2, y: baseline - 2, width: width + 4, height: height + 4)
    }

    /// A point in PDFKit page space as SyncTeX's (x, y) for an inverse search.
    static func synctexPoint(_ point: CGPoint, pageBounds: CGRect) -> CGPoint {
        CGPoint(x: point.x - pageBounds.minX, y: pageBounds.maxY - point.y)
    }
}
