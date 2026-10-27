import AppKit
import Foundation

extension ProjectModel {
    var livePreview: Bool {
        get { texpresso.active }
        set { if newValue { startTeXpresso() } else { stopTeXpresso() } }
    }

    var canSwitchLivePreview: Bool { app?.canPreviewLive == true && initialLoadComplete && texpresso.phase != .stopping }

    var liveEngine: String? {
        texpresso.engine.flatMap { engine in
            livePDF && engine != settings?.engine ? Engine(rawValue: engine)?.title ?? engine : nil
        }
    }

    func startTeXpresso() {
        guard !closed, let session, texpresso.phase == .stopped else { return }
        texpresso.starting()
        if let pages = pdf.visiblePages { liveView(pages) }
        liveCaret()
        core.send("session_live_start", ["session": session])
    }

    func stopTeXpresso() {
        guard let session else { return }
        texpresso.stopping()
        Task {
            if let state = try? await core.call("session_live_stop", ["session": session], as: LiveState.self), state.phase == .stopped,
               texpresso.phase == .stopping { liveChanged(state) }
        }
        Task { await endLivePDF() }
    }

    func liveView(_ pages: ClosedRange<Int>) {
        guard texpresso.active, let session else { return }
        core.send("session_live_view", ["session": session, "first": pages.lowerBound, "last": pages.upperBound])
    }

    func liveCaret() {
        guard texpresso.active, let session, let path = editor.path else { return }
        core.send("session_live_caret", ["session": session, "path": path, "offset": editor.caret])
    }

    func endLivePDF() async {
        guard livePDF, !texpresso.active, !(await showBuildPDF(buildPDF?.path(percentEncoded: false), replacingLive: true)), livePDF,
              !texpresso.active, !closed else { return }
        shown = .none
        pdf.clear()
    }

    func liveChanged(_ state: LiveState) {
        let was = texpresso.phase
        texpresso.receive(state)
        if state.alert == true { panel.show(.texpresso) }
        if state.phase == .stopped, was != .stopped { Task { await endLivePDF() } }
        if state.phase != .running { pdf.endLiveRun() }
    }

    func showLive(_ read: LiveRead) {
        guard texpresso.active, !closed else { return }
        if case .document(_?) = read {
            if !livePDF, app?.showPDF == false { app?.showPDF = true }
            shown = .live
        }
        pdf.showLive(read)
    }

    func forwardSync(quietly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column) = (editor.currentLine, editor.currentColumn)
        let live = livePDF, request = SynctexForward(id: id, file: path, line: line, live: liveSession)
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            let shown = pdf.shownVersion
            do {
                let loc = try await core.call(request)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown, livePDF == live else { return }
                app?.requestPDF(.reveal(loc, SyncSource(id: id, file: path, line: line, column: column, quietly: quietly)))
            } catch {
                if !quietly, !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    private var liveSession: UInt64? { livePDF ? session : nil }

    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil, quietly: Bool = false) async {
        await restart(&syncTask) { [self] in
            do {
                let loc = try await core.call(SynctexInverse(id: id, page: Double(page), x: x, y: y, click: click, live: liveSession))
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
