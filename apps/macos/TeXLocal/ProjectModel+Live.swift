import AppKit
import Foundation

extension ProjectModel {
    var livePreview: Bool {
        get { texpresso.active }
        set { if newValue { startTeXpresso() } else { stopTeXpresso() } }
    }

    var canSwitchLivePreview: Bool { app?.canPreviewLive == true && initialLoadComplete && texpresso.phase != .stopping }

    var liveEngine: String? {
        texpresso.engine.flatMap { engine in livePDF && engine != settings?.engine ? engine.title : nil }
    }

    func startTeXpresso() {
        guard !closed, let session, texpresso.phase == .stopped else { return }
        texpresso.starting()
        liveCaret()
        session.send(StartLive())
    }

    func stopTeXpresso() {
        guard let session else { return }
        texpresso.stopping()
        session.send(StopLive())
    }

    func liveView(_ pages: ClosedRange<Int>) {
        guard let session else { return }
        session.send(LiveView(first: pages.lowerBound, last: pages.upperBound))
    }

    func liveCaret() {
        guard texpresso.active, let session, let path = editor.path else { return }
        session.send(LiveCaret(path: path, offset: editor.caret))
    }

    func liveChanged(_ state: LiveState) {
        texpresso.receive(state)
        if state.phase != .running { followsCaret = false }
        showIssues()
    }

    private var showsLive: Bool { !closed && texpresso.active && livePDF }

    func showLive(_ live: LiveDocument) {
        _ = enqueue(&liveReads) { [self] in
            guard let document = await PDFController.loadDocument(URL(filePath: live.path)), showsLive else { return }
            pdf.show(document)
            if followsCaret { followCaret() }
        }
    }

    func showLive(_ live: LivePage) {
        _ = enqueue(&liveReads) { [self] in
            guard let page = await PDFController.loadPage(live.pdf), showsLive else { return }
            pdf.show(page, at: live.page)
        }
    }

    private func followCaret() {
        guard let session, let path = openPath, isLaTeX else { return }
        let line = editor.currentLine
        _ = restart(&followTask) { [self] in
            guard let loc = try? await session.call(SynctexForward(file: path, line: line)), !Task.isCancelled, !closed, livePDF,
                  openPath == path else { return }
            followsCaret = false
            pdf.follow(loc)
        }
    }

    func forwardSync(quietly: Bool = false) async {
        guard let session, let path = openPath else { return }
        let (line, column) = (editor.currentLine, editor.currentColumn)
        let request = SynctexForward(file: path, line: line)
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            let shown = pdf.shownVersion
            do {
                let loc = try await session.call(request)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown else { return }
                app?.requestPDF(.reveal(loc, SyncSource(session: session.id, file: path, line: line, column: column, quietly: quietly)))
            } catch {
                if !quietly, !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil, quietly: Bool = false) async {
        guard let session else { return }
        await restart(&syncTask) { [self] in
            do {
                let loc = try await session.call(SynctexInverse(page: Double(page), x: x, y: y, click: click))
                guard !Task.isCancelled, !closed, !quietly || loc.column != nil else { return }
                await open(loc.file, line: loc.line, column: loc.column, jump: true)
            } catch {
                if !quietly, !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Spot in the Source") }
            }
        }.value
    }

    private func reportSync(_ error: any Error, _ title: String) {
        guard (error as? CoreError)?.kind == .notFound else { app?.report(error, title); return }
        NSSound.beep()
        notices.note(error.localizedDescription)
    }
}
