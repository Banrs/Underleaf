import PDFKit
import os

/// Live Preview's feed. While you type TeXpresso sends the pages in view, each as a one-page PDF; after a pause it
/// writes the whole document, with the pages that changed since the one it wrote before. One read runs at a time, off
/// the main thread; what arrives meanwhile waits coalesced: one document, whose changed pages merge, and pages by index,
/// the newest winning, which a newer document drops.
struct LiveFeed {
    var document: (path: String, changed: IndexSet)?
    var pages: [Int: Data] = [:]
    var reading: Task<Void, Never>?
    /// The live document shown, which the next one may change in place.
    weak var shown: PDFDocument?
}

/// Pages pulled out of the document they were read from, by the index they replace, so that the document shown can
/// take them; `count` is the new document's page count, nil for single pages.
nonisolated struct LivePages {
    var pages: [Int: PDFPage] = [:]
    var count: Int?
    var covers: [Int: CGImage] = [:]
}

extension PDFController {
    /// Measured on 392 pages, a swap takes 7–15 ms on the main thread and replacing a page 1–2 ms, so beyond this many
    /// changed pages the whole document is shown instead.
    static let changedInPlace = 8

    var liveReading: Task<Void, Never>? { feed.reading }

    func showLive(_ live: LiveDocument) {
        var changed = feed.document?.changed ?? []
        for range in live.changed { changed.insert(integersIn: range.first...range.last) }
        feed.document = (live.path, changed)
        feed.pages = [:]
        readLive()
    }

    func showLive(_ live: LivePage) {
        feed.pages[live.page] = live.pdf
        readLive()
    }

    func stopLive() {
        feed.reading?.cancel()
        feed = LiveFeed()
    }

    private func readLive() {
        guard feed.reading == nil else { return }
        feed.reading = Task { [weak self] in
            while let self, !Task.isCancelled {
                if let document = feed.document.take() {
                    await readLive(URL(filePath: document.path), changed: document.changed)
                } else if !feed.pages.isEmpty {
                    let pages = feed.pages
                    feed.pages = [:]
                    if let live = await Self.loadPages(pages, covering: view.coverPages), !Task.isCancelled { replace(live) }
                } else {
                    break
                }
            }
            if !Task.isCancelled { self?.feed.reading = nil }
        }
    }

    private func readLive(_ url: URL, changed: IndexSet) async {
        let shown = view.document, wanted = view.coverPages
        if shown != nil, shown === feed.shown, changed.count <= Self.changedInPlace {
            guard let live = await Self.loadPages(changed, of: url, covering: wanted), !Task.isCancelled else { return feed.shown = nil }
            replace(live)
        } else {
            guard let loaded = await Self.loadDocument(url, covering: wanted), !Task.isCancelled else { return feed.shown = nil }
            signposts.withIntervalSignpost("live.document") { show(loaded.document, covers: loaded.covers) }
            feed.shown = loaded.document
        }
    }

    /// Replaces pages in the document shown, which keeps its place, selection and find, and trims it to the new count.
    private func replace(_ live: LivePages) {
        let interval = signposts.beginInterval("live.page")
        defer { signposts.endInterval("live.page", interval) }
        guard let document = view.document else { return }
        let refind = find.isRunning
        find.cancel()
        var swaps: [(old: PDFPage, new: PDFPage?)] = []
        view.covering(live.covers) {
            for (index, page) in live.pages.sorted(by: { $0.key < $1.key }) {
                if let old = document.page(ifAt: index) {
                    document.insert(page, at: index)
                    document.removePage(at: index + 1)
                    swaps.append((old, page))
                } else if live.count != nil, index == document.pageCount {
                    document.insert(page, at: index)
                }
            }
            while let count = live.count, document.pageCount > count, let last = document.page(at: document.pageCount - 1) {
                document.removePage(at: document.pageCount - 1)
                swaps.append((last, nil))
            }
        }
        let gone = swaps.map(\.old)
        if let mark = view.mark, gone.contains(mark.page) { view.removeMark() }
        if view.currentSelection?.pages.contains(where: gone.contains) == true { view.clearSelection() }
        pageChanged()
        if refind { find.rerun() } else { find.replaced(swaps) }
    }

    @concurrent private static func loadPages(_ changed: IndexSet, of url: URL, covering wanted: CoverPages) async -> sending LivePages? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        var live = LivePages(count: document.pageCount)
        live.covers = SyncPDFView.covers(CoverPages(indices: wanted.indices.filter(changed.contains), scale: wanted.scale), of: document)
        for index in changed.reversed() {
            guard let page = document.page(ifAt: index) else { continue }
            page.hideLinkBorders()
            document.removePage(at: index)
            live.pages[index] = page
        }
        return live
    }

    @concurrent private static func loadPages(_ pdfs: [Int: Data], covering wanted: CoverPages) async -> sending LivePages? {
        var live = LivePages()
        for (index, pdf) in pdfs {
            guard let document = PDFDocument(data: pdf), let page = document.page(at: 0) else { continue }
            if wanted.indices.contains(index) {
                live.covers[index] = SyncPDFView.covers(CoverPages(indices: [0], scale: wanted.scale), of: document)[0]
            }
            page.hideLinkBorders()
            document.removePage(at: 0)
            live.pages[index] = page
        }
        return live
    }
}
