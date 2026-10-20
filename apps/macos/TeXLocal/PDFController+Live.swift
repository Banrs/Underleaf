import PDFKit

/// Live Preview's pages: drawn over PDFKit's at once, then taken into its document a few at a time.
extension PDFController {
    /// A page drawn over PDFKit's waits this long for its whole document, which comes 300 ms after the last key.
    private static let liveSettleDelay: Duration = .seconds(1)
    /// PDFKit fades a page it is given in over about 240 ms (27.2); the layers over its pages go after that.
    private static let liveClearDelay: Duration = .milliseconds(400)

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

    func endLiveRun() { (liveMissed, liveShown) = (false, false) }

    /// Over PDFKit's page until its document takes it as the typing pauses, so a key costs one drawing.
    func showLive(_ page: PDFPage, at index: Int) {
        guard let shown = view.document?.page(ifAt: index) else { return }
        liveWaiting[index] = page
        liveBacklog?.pages.remove(index)
        guard view.showLive(page, over: shown, at: index) else { return settleLive() }
        liveClearing?.cancel()
        restart(&liveSettling, after: Self.liveSettleDelay) { [weak self] in self?.settleLive() }
    }

    private func settleLive() {
        guard let document = view.document, !liveWaiting.isEmpty else { return }
        var gone: Set<PDFPage> = []
        // Not a page a whole document is still bringing (`takeLive`), which would go in twice.
        for (index, page) in liveWaiting where liveBacklog?.pages.contains(index) != true {
            liveWaiting[index] = nil
            if let old = document.replacePage(at: index, with: page) { gone.insert(old) }
        }
        replaced(gone)
    }

    /// A live page is drawn only where its page showed, so PDFKit takes the waiting ones for what comes into view.
    func scrolled() {
        guard !liveWaiting.isEmpty else { return }
        Task { [weak self] in self?.settleLive() }
    }

    /// `changed` nil: any page may differ.
    func showLive(_ document: PDFDocument, changed: IndexSet?, complete: Bool) {
        guard let shown = view.document, var pages = changed, !(complete && hasGrown) else { return show(document) }
        if let liveBacklog { pages.formUnion(liveBacklog.pages) }
        if shown.pageCount < document.pageCount { pages.insert(integersIn: shown.pageCount..<document.pageCount) }
        pages.formIntersection(IndexSet(integersIn: 0..<document.pageCount))
        liveBacklog = (document, pages, complete)
        takeLive()
    }

    /// A few milliseconds' worth a turn, the first at once, so a long document doesn't stop the typing.
    private func takeLive() {
        guard takeLiveShare(), liveTaking == nil else { return }
        liveTaking = Task { [weak self] in
            repeat { await Task.yield() } while self?.takeLiveShare() == true
            self?.liveTaking = nil
        }
    }

    /// Whether pages are left for the next turn.
    private func takeLiveShare() -> Bool {
        guard let shown = view.document, var backlog = liveBacklog else { return false }
        liveBacklog = nil
        let start = ContinuousClock.now
        var gone: Set<PDFPage> = [], came = false
        while let index = backlog.pages.first, index <= shown.pageCount, ContinuousClock.now - start < .milliseconds(4) {
            backlog.pages.remove(index)
            guard let page = backlog.document.page(at: index)?.copy() as? PDFPage else { continue }
            // A page in view goes in beneath a layer that shows it already, as PDFKit fades a new one in.
            if let old = shown.page(ifAt: index), liveWaiting.removeValue(forKey: index) == nil, !view.hasLive(at: index) {
                _ = view.showLive(page, over: old, at: index)
            }
            if let old = shown.replacePage(at: index, with: page) { gone.insert(old) } else { shown.insert(page, at: index) }
            came = true
        }
        if backlog.pages.first.map({ $0 <= shown.pageCount }) == true {
            liveBacklog = backlog
        } else if backlog.complete {
            while shown.pageCount > backlog.document.pageCount, let last = shown.page(at: shown.pageCount - 1) {
                liveWaiting[shown.pageCount - 1] = nil
                view.removeLive(at: shown.pageCount - 1)
                shown.removePage(at: shown.pageCount - 1)
                gone.insert(last)
            }
        }
        // Pages that came or went at the end leave the others where they were: the document view counts from its top.
        if gone.isEmpty, came { pageChanged() }
        replaced(gone)
        return liveBacklog != nil
    }

    private func replaced(_ gone: Set<PDFPage>) {
        guard !gone.isEmpty else { return }
        clearLiveLater()
        if view.currentSelection?.pages.contains(where: gone.contains) == true { view.clearSelection() }
        if let mark = view.mark, gone.contains(mark.page) { view.removeMark() }
        pageChanged()
        find.pagesReplaced(gone)
    }

    /// Once PDFKit has drawn its own pages' tiles and faded them in beneath (27.2).
    func clearLiveLater() {
        restart(&liveClearing, after: Self.liveClearDelay) { [weak self] in
            if let self, liveWaiting.isEmpty { view.removeLive() }
        }
    }

    func dropLive() {
        liveSettling?.cancel()
        settleLive()
        liveClearing?.cancel()
        view.removeLive()
    }

    func resetLive() {
        liveWaiting.removeAll()
        (liveBacklog, liveMissed, liveShown) = (nil, false, false)
    }
}
