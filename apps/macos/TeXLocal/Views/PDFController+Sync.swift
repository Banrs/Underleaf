import PDFKit

extension PDFController {
    func highlight(_ selection: PDFSelection?, or rect: CGRect, on page: PDFPage) {
        if let selection, !find.isOpen {
            view.removeMark()
            selection.color = .findHighlightColor
            view.setCurrentSelection(selection, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            view.flash(rect, on: page)
        }
    }

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

    func reveal(_ loc: ForwardLoc, from source: SyncSource? = nil) {
        guard view.hasShownArea else {
            pendingReveal = (loc, source)
            return
        }
        pendingReveal = nil
        revealing?.cancel()
        guard let document = view.document, let located = document.page(ifAt: Int(loc.page) - 1) else { return }
        guard let source else { return showFound(loc, on: located, hit: nil) }
        let pages = syncPages(loc.matches, in: document)
        let read = pages.map(\.page) + [located]
        let match = SynctexMatch(file: source.file, line: source.line, column: source.column, pages: pages.map(\.text))
        revealing = Task {
            let hit = try? await source.session.call(match)
            guard !Task.isCancelled, view.document === document, read.allSatisfy({ document.number(of: $0) != nil }),
                  !source.wordOnly || hit != nil else { return }
            showFound(loc, on: located, hit: hit)
        }
    }

    private func showFound(_ loc: ForwardLoc, on located: PDFPage, hit: PdfHit?) {
        var found: (page: PDFPage, selection: PDFSelection)?
        if let hit, hit.end > hit.start, let page = view.document?.page(ifAt: hit.page - 1),
           let selection = page.selection(for: NSRange(hit.start..<hit.end)) {
            found = (page, selection)
        }
        let page = found?.page ?? located
        let rect = found.map { $0.selection.bounds(for: $0.page) }
            ?? SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        show(rect, on: page)
        highlight(found?.selection, or: rect, on: page)
    }

    func follow(_ loc: ForwardLoc) {
        guard view.hasShownArea, let page = view.document?.page(ifAt: Int(loc.page) - 1) else { return }
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        if !view.shownRect.contains(view.convert(rect, from: page)) { show(rect, on: page) }
    }

    private func show(_ rect: CGRect, on page: PDFPage) {
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
    }

    private func syncPages(_ boxes: [ForwardLoc], in document: PDFDocument) -> [(page: PDFPage, text: PdfPage)] {
        let numbers = boxes.map { Int($0.page) }
        guard let lowest = numbers.min(), let highest = numbers.max() else { return [] }
        let first = max(1, lowest - 1), last = min(document.pageCount, highest + 1)
        guard first <= last else { return [] }
        return (first...last).compactMap { number in
            guard let page = document.page(ifAt: number - 1), let text = page.string else { return nil }
            let bounds = page.bounds(for: view.displayBox)
            var near: [TextRange] = []
            for box in boxes where Int(box.page) == number {
                guard let covered = page.selection(for: SyncTeXGeometry.highlightRect(box, pageBounds: bounds)) else { continue }
                for index in 0..<covered.numberOfTextRanges(on: page) {
                    let range = covered.range(at: index, on: page)
                    if range.location != NSNotFound, range.length > 0 { near.append(TextRange(start: range.location, length: range.length)) }
                }
            }
            return (page, PdfPage(page: number, text: text, near: near))
        }
    }
}

enum SyncTeXGeometry {
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
    func click(at point: CGPoint) -> PageClick? {
        guard document != nil, let word = selectionForWord(at: point), let text = string else { return nil }
        let range = word.range(at: 0, on: self)
        guard range.location != NSNotFound else { return nil }
        let offset = (0..<range.length).first { i in
            selection(for: NSRange(location: range.location + i, length: 1)).map { $0.bounds(for: self).maxX > point.x } ?? false
        }
        return PageClick(text: text, at: range.location + (offset ?? 0))
    }
}
