import PDFKit

extension PDFController {
    func showLive(_ read: LiveRead) {
        switch read {
        case .document(let live?):
            // After a document that wasn't read, any page may differ from what shows.
            let changed = liveMissed && live.changed != nil ? IndexSet(integersIn: 0..<live.document.pageCount) : live.changed
            liveMissed = false
            showLive(live.document, changed: changed, complete: live.complete)
            liveShown = true
        case .document(nil):
            liveMissed = true
        case .page(let live?) where liveShown:
            showLive(live.page, at: live.index)
        case .page:
            break
        }
    }

    func endLiveRun() {
        liveTaking?.cancel()
        (liveTaking, livePending) = (nil, nil)
        (liveMissed, liveShown) = (false, false)
    }

    func showLive(_ page: PDFPage, at index: Int) {
        livePending?.pages.remove(index)
        guard let gone = view.document?.replacePage(at: index, with: page) else { return }
        replaced([gone])
    }

    func showLive(_ document: PDFDocument, changed: IndexSet?, complete: Bool) {
        guard let shown = view.document, var pages = changed, !(complete && hasGrown) else { return show(document) }
        if let livePending { pages.formUnion(livePending.pages) }
        if shown.pageCount < document.pageCount { pages.insert(integersIn: shown.pageCount..<document.pageCount) }
        pages.formIntersection(IndexSet(integersIn: 0..<document.pageCount))
        livePending = (document, pages, complete)
        guard takeLiveBatch(), liveTaking == nil else { return }
        liveTaking = Task { [weak self] in
            repeat {
                await Task.yield()
                guard !Task.isCancelled else { return }
            } while self?.takeLiveBatch() == true
            self?.liveTaking = nil
        }
    }

    /// Bound each main-actor turn so a long document doesn't hold up typing.
    private func takeLiveBatch() -> Bool {
        guard let shown = view.document, var pending = livePending else { return false }
        var gone: Set<PDFPage> = []
        for index in pending.pages.prefix(16) {
            pending.pages.remove(index)
            guard let page = pending.document.page(at: index)?.copy() as? PDFPage else { continue }
            if let old = shown.replacePage(at: index, with: page) { gone.insert(old) } else { shown.insert(page, at: index) }
        }
        // A partial run has not reached the remaining pages; keep them until TeX finishes.
        if pending.pages.isEmpty && pending.complete {
            while shown.pageCount > pending.document.pageCount, let last = shown.page(at: shown.pageCount - 1) {
                shown.removePage(at: shown.pageCount - 1)
                gone.insert(last)
            }
        }
        livePending = pending.pages.isEmpty ? nil : pending
        replaced(gone)
        return livePending != nil
    }

    private func replaced(_ gone: Set<PDFPage>) {
        if view.currentSelection?.pages.contains(where: gone.contains) == true { view.clearSelection() }
        if let mark = view.mark, gone.contains(mark.page) { view.removeMark() }
        pageChanged()
        find.pagesReplaced(gone)
    }
}
