import Foundation
import os

extension ProjectModel {
    var livePhase: LivePhase { store.live?.phase ?? .stopped }
    var liveActive: Bool { livePhase == .starting || livePhase == .running }
    var liveNeedsAttention: Bool { store.live?.attention == true }
    var liveTitle: LocalizedStringResource {
        switch livePhase {
        case .stopped: liveNeedsAttention ? "Live Preview Needs Attention" : "Live Preview Stopped"
        case .starting: "Starting Live Preview…"
        case .running:
            store.live?.halted == true ? "Live Preview Paused at an Error"
                : liveNeedsAttention ? "Live Preview Needs Attention" : "Live Preview On"
        }
    }
    var liveLog: String {
        guard let live = store.live else { return "" }
        return (live.failures.map(\.text) + [store.liveLog ?? ""]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var livePreview: Bool {
        get { liveActive }
        set { if newValue { startTeXpresso() } else { session.send(StopLive()) } }
    }

    var canSwitchLivePreview: Bool { window?.app.canPreviewLive == true && initialLoadComplete }

    var showsLive: Bool { !closed && liveActive && livePDF }

    var liveEngine: String? {
        (store.live?.engine).flatMap { engine in livePDF && engine != settings?.engine ? engine.title : nil }
    }

    func startTeXpresso() {
        guard livePhase == .stopped else { return }
        session.send(StartLive())
    }

    func liveView(_ pages: ClosedRange<Int>) {
        session.send(LiveView(first: pages.lowerBound, last: pages.upperBound))
    }

    func canSyncForward(quietly: Bool = false) -> Bool { hasPDF && isLaTeX && (!quietly || window?.showPDF == true) }

    func forwardSync(quietly: Bool = false, wordOnly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column) = (cursorLine, cursorColumn)
        let request = SynctexForward(file: path, line: line)
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, openPath == path else { return }
            weak let shown = views?.shownPDF
            do {
                let loc: ForwardLoc
                do {
                    let interval = signposts.beginInterval("sync.forward")
                    defer { signposts.endInterval("sync.forward", interval) }
                    loc = try await session.call(request)
                }
                guard !Task.isCancelled, openPath == path, views?.shownPDF === shown, !quietly || window?.showPDF == true else { return }
                window?.requestPDF(.reveal(loc, SyncSource(session: session, file: path, line: line, column: column, wordOnly: wordOnly)))
            } catch {
                if !quietly, !Task.isCancelled { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil, quietly: Bool = false) async {
        guard !quietly || window?.showSource == true else { return }
        await restart(&syncTask) { [self] in
            do {
                let loc = try await session.call(SynctexInverse(page: Double(page), x: x, y: y, click: click))
                guard !Task.isCancelled, !quietly || loc.column != nil, !quietly || window?.showSource == true else { return }
                await open(loc.file, line: loc.line, column: loc.column, jump: true)
            } catch {
                if !quietly, !Task.isCancelled { reportSync(error, "Couldn’t Find This Spot in the Source") }
            }
        }.value
    }

    private func reportSync(_ error: any Error, _ title: String) {
        guard (error as? CoreError)?.kind == .notFound else { window?.report(title, error); return }
        views?.beep()
        notices.note(error.localizedDescription)
    }
}
