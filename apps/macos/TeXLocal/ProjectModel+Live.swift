import Foundation

extension ProjectModel {
    var livePreview: Bool {
        get { texpresso.active }
        set { if newValue { startTeXpresso() } else { session.send(StopLive()) } }
    }

    var canSwitchLivePreview: Bool { app?.canPreviewLive == true && initialLoadComplete && texpresso.phase != .stopping }

    var liveEngine: String? {
        texpresso.engine.flatMap { engine in livePDF && engine != settings?.engine ? engine.title : nil }
    }

    func startTeXpresso() {
        guard texpresso.phase == .stopped else { return }
        if let caret { session.send(LiveCaret(path: caret.path, offset: caret.offset)) }
        session.send(StartLive())
    }

    func liveView(_ pages: ClosedRange<Int>) {
        session.send(LiveView(first: pages.lowerBound, last: pages.upperBound))
    }

    func liveCaret() {
        guard texpresso.active, let caret else { return }
        session.send(LiveCaret(path: caret.path, offset: caret.offset))
    }

    func forwardSync(quietly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column) = (cursorLine, cursorColumn)
        let request = SynctexForward(file: path, line: line)
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, openPath == path else { return }
            let shown = views?.shownVersion
            do {
                let loc = try await session.call(request)
                guard !Task.isCancelled, openPath == path, views?.shownVersion == shown else { return }
                app?.requestPDF(.reveal(loc, SyncSource(session: session, file: path, line: line, column: column, quietly: quietly)))
            } catch {
                if !quietly, !Task.isCancelled { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil, quietly: Bool = false) async {
        await restart(&syncTask) { [self] in
            do {
                let loc = try await session.call(SynctexInverse(page: Double(page), x: x, y: y, click: click))
                guard !Task.isCancelled, !quietly || loc.column != nil else { return }
                await open(loc.file, line: loc.line, column: loc.column, jump: true)
            } catch {
                if !quietly, !Task.isCancelled { reportSync(error, "Couldn’t Find This Spot in the Source") }
            }
        }.value
    }

    private func reportSync(_ error: any Error, _ title: String) {
        guard (error as? CoreError)?.kind == .notFound else { app?.report(title, error); return }
        views?.beep()
        notices.note(error.localizedDescription)
    }
}
