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

    /// What a project keeps of the view, the restored place while it waits.
    var keptPage: Int? { restorePage ?? (page > 0 ? page : nil) }
    var keptZoom: Zoom { restoreZoom ?? zoom }

    @objc func pageChanged() {
        guard let document = view.document, let page = view.currentPage else { return }
        if let number = document.number(of: page) { self.page = number }
        pageCount = document.pageCount
    }

    var visiblePages: ClosedRange<Int>? {
        guard let document = view.document, view.hasShownArea else { return nil }
        let shown = view.visiblePages.map { document.index(for: $0) }.filter { $0 != NSNotFound }
        return shown.min().flatMap { first in shown.max().map { first...$0 } }
    }

    @objc func visiblePagesChanged() {
        guard let pages = visiblePages, pages != toldPages else { return }
        toldPages = pages
        onVisiblePages(pages)
    }

    func apply(_ zoom: Zoom) {
        switch zoom {
        case .fitWidth: fitWidth()
        case .fitPage: fitPage()
        case .scale(let scale): setScale(CGFloat(scale))
        }
    }

    func go(toPage number: Int) {
        if let document = view.document, let page = document.page(ifAt: min(max(number, 1), document.pageCount) - 1) { view.go(to: page) }
    }

    func fitWidth() {
        zoom = .fitWidth
        view.autoScales = true
    }

    /// The zoom before the page: where a page lands depends on the scale.
    func restoreIfReady() {
        guard view.document != nil, view.hasShownArea else { return }
        if let zoom = restoreZoom.take() { apply(zoom) }
        if let number = restorePage.take() { go(toPage: number) }
    }

    /// SyncTeX resolves only points on a glyph box, and the page centre is usually whitespace: the probe walks down to a
    /// line of text.
    func sourcePoint() -> (page: Int, point: CGPoint)? {
        guard let document = view.document else { return nil }
        let probe = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - view.safeAreaInsets.top - view.shownHeight * 0.2)
        guard let page = view.page(for: probe, nearest: true), let number = document.number(of: page) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        var point = view.convert(probe, to: page)
        while point.y > bounds.minY {
            if let line = page.selectionForLine(at: point), let text = line.string, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let box = line.bounds(for: page)
                point = CGPoint(x: box.midX, y: box.minY)
                break
            }
            point.y -= 6
        }
        return (number, SyncTeXGeometry.synctexPoint(point, pageBounds: bounds))
    }

    /// As a project's ui state keeps it (docs/core-api.md): "fitWidth", "fitPage" or a scale.
    nonisolated enum Zoom: Decodable, Hashable {
        case fitWidth, fitPage, scale(Double)

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let scale = try? value.decode(Double.self) {
                self = .scale(scale)
            } else {
                self = try value.decode(String.self) == "fitPage" ? .fitPage : .fitWidth
            }
        }

        var json: any Sendable {
            switch self {
            case .fitWidth: "fitWidth"
            case .fitPage: "fitPage"
            case .scale(let scale): scale
            }
        }
    }

    /// The source's word, found by the core in the text round SyncTeX's boxes (`synctex_match`), is selected; where it
    /// isn't found once, SyncTeX's box flashes.
    func reveal(_ loc: ForwardLoc, from source: SyncSource? = nil) {
        guard view.hasShownArea else {
            pendingReveal = (loc, source)
            return
        }
        pendingReveal = nil
        revealing?.cancel()
        guard let document = view.document, let located = document.page(ifAt: Int(loc.page) - 1) else { return }
        guard let source else { return showFound(loc, on: located, hit: nil) }
        let pages = syncPages(loc.matches ?? [loc], in: document)
        let read = pages.map(\.page) + [located]
        revealing = Task {
            let hit = try? await Core.shared.call("synctex_match", ["id": source.id, "file": source.file, "line": source.line,
                                                                    "column": source.column, "pages": pages.map(\.args)],
                                                  as: PageHit?.self)
            // The match is for the pages that were read, which a rebuild or a live page may have replaced.
            guard !Task.isCancelled, view.document === document, read.allSatisfy({ document.number(of: $0) != nil }) else { return }
            showFound(loc, on: located, hit: hit)
        }
    }

    private func showFound(_ loc: ForwardLoc, on located: PDFPage, hit: PageHit?) {
        var found: (page: PDFPage, selection: PDFSelection)?
        if let hit, hit.end > hit.start, let page = view.document?.page(ifAt: hit.page - 1),
           let selection = page.selection(for: NSRange(hit.start..<hit.end)) {
            found = (page, selection)
        }
        let page = found?.page ?? located
        let rect = found.map { $0.selection.bounds(for: $0.page) }
            ?? SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
        highlight(found?.selection, or: rect, on: page)
    }

    /// A page either side of SyncTeX's boxes, as the line can wrap past the first and TeX be a page on.
    private func syncPages(_ boxes: [ForwardLoc], in document: PDFDocument) -> [(page: PDFPage, args: [String: any Sendable])] {
        let numbers = boxes.map { Int($0.page) }
        guard let lowest = numbers.min(), let highest = numbers.max() else { return [] }
        let first = max(1, lowest - 1), last = min(document.pageCount, highest + 1)
        guard first <= last else { return [] }
        return (first...last).compactMap { number in
            guard let page = document.page(ifAt: number - 1), let text = page.string else { return nil }
            let bounds = page.bounds(for: view.displayBox)
            var near: [[Int]] = []
            for box in boxes where Int(box.page) == number {
                guard let covered = page.selection(for: SyncTeXGeometry.highlightRect(box, pageBounds: bounds)) else { continue }
                for index in 0..<covered.numberOfTextRanges(on: page) {
                    let range = covered.range(at: index, on: page)
                    if range.location != NSNotFound, range.length > 0 { near.append([range.location, NSMaxRange(range)]) }
                }
            }
            return (page, ["page": number, "text": text, "near": near])
        }
    }
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
    /// The page's text and the clicked letter's index in it, for the core to find in the source. `characterIndex` is a letter
    /// behind for each line above, so each letter's selection is measured instead (`aClickSendsThePagesTextAndTheLetter`).
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
