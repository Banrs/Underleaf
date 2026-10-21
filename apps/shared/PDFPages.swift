import PDFKit

/// What both apps do with a build's PDF and SyncTeX's points, whatever view shows them.
extension PDFController {
    /// Read whole: the next build rewrites the file in place.
    @concurrent static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        for index in 0..<document.pageCount {
            for link in document.page(at: index)?.annotations ?? [] where link.type == "Link" {
                let border = PDFBorder()
                border.lineWidth = 0
                link.border = border
            }
        }
        return document
    }

    nonisolated enum Zoom: Codable, Hashable { case fitWidth, fitPage, scale(Double) }
}

extension PDFDocument {
    /// `page(at:)` raises outside the document.
    func page(ifAt index: Int) -> PDFPage? { (0..<pageCount).contains(index) ? page(at: index) : nil }

    /// PDFKit answers NSNotFound for a page that has left the document.
    func number(of page: PDFPage) -> Int? {
        let index = index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    /// `new` in before the old page out, so the document is never shorter than the place being read.
    func replacePage(at index: Int, with new: PDFPage) -> PDFPage? {
        guard let old = page(ifAt: index) else { return nil }
        insert(new, at: index)
        removePage(at: index + 1)
        return old
    }

    func replacePages(with other: PDFDocument) {
        let pages = (0..<other.pageCount).compactMap { other.page(at: $0)?.copy() as? PDFPage }
        for (index, page) in pages.enumerated() {
            if replacePage(at: index, with: page) == nil { insert(page, at: index) }
        }
        while pageCount > pages.count { removePage(at: pageCount - 1) }
        func here(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let target = destination.page, target.document === other,
                  let page = page(ifAt: other.index(for: target)) else { return nil }
            let local = PDFDestination(page: page, at: destination.point)
            local.zoom = destination.zoom
            return local
        }
        for link in pages.flatMap(\.annotations) where link.type == "Link" {
            if let destination = here(link.destination) { link.destination = destination }
            if let goTo = link.action as? PDFActionGoTo, let destination = here(goTo.destination) {
                link.action = PDFActionGoTo(destination: destination)
            }
        }
    }
}

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

extension PDFPage {
    /// The page's text and the clicked letter's index in it, for the core to find in the source. 27.2: `characterIndex` is
    /// wrong for pdfTeX's T1 fonts, so each letter's selection is measured instead.
    func click(at point: CGPoint) -> PageClick? {
        // PDFKit's word lookup crashes on a page whose document has gone.
        guard document != nil, let word = selectionForWord(at: point), let text = string else { return nil }
        let range = word.range(at: 0, on: self)
        guard range.location != NSNotFound else { return nil }
        let offset = (0..<range.length).first { i in
            selection(for: NSRange(location: range.location + i, length: 1)).map { $0.bounds(for: self).maxX > point.x } ?? false
        }
        return PageClick(text: text, at: range.location + (offset ?? 0))
    }
}
