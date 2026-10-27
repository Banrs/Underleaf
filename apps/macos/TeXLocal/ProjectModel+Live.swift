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
        if let pages = pdf.visiblePages { liveView(pages) }
        liveCaret()
        session.send(StartLive())
    }

    func stopTeXpresso() {
        guard let session else { return }
        texpresso.stopping()
        Task {
            if let state = try? await session.call(StopLive()), state.phase == .stopped,
               texpresso.phase == .stopping { liveChanged(state) }
        }
        Task { await endLivePDF() }
    }

    func liveView(_ pages: ClosedRange<Int>) {
        guard texpresso.active, let session else { return }
        session.send(LiveView(first: pages.lowerBound, last: pages.upperBound))
    }

    func liveCaret() {
        guard texpresso.active, let session, let path = editor.path else { return }
        session.send(LiveCaret(path: path, offset: editor.caret))
    }

    func endLivePDF() async {
        guard livePDF, !texpresso.active, !(await showBuildPDF(buildPDF?.path(percentEncoded: false), replacingLive: true)), livePDF,
              !texpresso.active, !closed else { return }
        shown = .none
        pdf.clear()
    }

    func liveChanged(_ state: LiveState, alert: Bool = false) {
        let was = texpresso.phase
        texpresso.receive(state, alert: alert)
        if alert { panel.show(.texpresso) }
        if state.phase == .stopped, was != .stopped { Task { await endLivePDF() } }
        if state.phase != .running { pdf.endLiveRun() }
    }

    func showLive(_ read: LiveRead) {
        guard texpresso.active, !closed else { return }
        if case .document(_?, _, _) = read {
            if !livePDF, app?.showPDF == false { app?.showPDF = true }
            shown = .live
        }
        pdf.showLive(read)
    }

    func forwardSync(quietly: Bool = false) async {
        guard let session, let path = openPath else { return }
        let (line, column) = (editor.currentLine, editor.currentColumn)
        let live = livePDF, request = SynctexForward(file: path, line: line)
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            let shown = pdf.shownVersion
            do {
                let loc = try await session.call(request)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown, livePDF == live else { return }
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
