#if os(macOS)
import AppKit
#endif
import Foundation

/// Live Preview, which the session runs, and SyncTeX between the source and either PDF.
extension ProjectModel {
    // MARK: - Live preview

    /// The inspector's toggle and the Compile menu's.
    var livePreview: Bool {
        get { texpresso.active }
        set { if newValue { startTeXpresso() } else { stopTeXpresso() } }
    }

    var canSwitchLivePreview: Bool { app?.canPreviewLive == true && initialLoadComplete && texpresso.phase != .stopping }

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
            // A preview that had ended already sends no event.
            if let state = try? await core.call("session_live_stop", ["session": session], as: LiveState.self), state.phase == .stopped,
               texpresso.phase == .stopping { liveChanged(state) }
        }
        // Its pages go now, not as the stop ends.
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

    /// The build's PDF, or none, in place of the live one: at Stop and again as the session says it ended, whose load
    /// takes over the first's.
    func endLivePDF() async {
        guard livePDF, !texpresso.active, !(await showBuildPDF(buildPDF?.path(percentEncoded: false), replacingLive: true)), livePDF,
              !texpresso.active, !closed else { return }
        shown = .none
        pdf.clear()
    }

    /// A run's PDFs start afresh.
    func liveChanged(_ state: LiveState) {
        let was = texpresso.phase
        texpresso.receive(state)
        if state.alert == true { panel.show(.texpresso) }
        if state.phase == .stopped, was != .stopped { Task { await endLivePDF() } }
        if state.phase != .running { pdf.endLiveRun() }
    }

    /// Read where the event arrived, in the session's order; a page is drawn over its own run's document only.
    func showLive(_ read: LiveRead) {
        guard texpresso.active, !closed else { return }
        if case .document(_?) = read {
            if !livePDF, app?.showPDF == false { app?.showPDF = true }
            shown = .live
        }
        pdf.showLive(read)
    }

    // MARK: - SyncTeX

    func forwardSync(quietly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column) = (editor.currentLine, editor.currentColumn)
        let live = livePDF, args = syncArguments(["id": id, "file": path, "line": line])
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            // A rebuild may have moved it.
            let shown = pdf.shownVersion
            do {
                let loc = try await core.call("synctex_forward", args, as: ForwardLoc.self)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown, livePDF == live else { return }
                app?.requestPDF(.reveal(loc, SyncSource(id: id, file: path, line: line, column: column)))
            } catch {
                if !quietly, !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    private func syncArguments(_ arguments: [String: any Sendable]) -> [String: any Sendable] {
        guard livePDF, let session else { return arguments }
        return arguments.merging(["live": true, "session": session]) { $1 }
    }

    /// With the click, the core finds its word in the lines round SyncTeX's.
    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil) async {
        await restart(&syncTask) { [self] in
            do {
                let args = syncArguments(["id": id, "page": page, "x": x, "y": y, "text": click?.text, "at": click?.at])
                let loc = try await core.call("synctex_inverse", args, as: InverseLoc.self)
                guard !Task.isCancelled, !closed else { return }
                await open(loc.file, line: loc.line, column: loc.column)
            } catch {
                if !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Spot in the Source") }
            }
        }.value
    }

    /// No match is ordinary (a comment, the preamble, a figure).
    private func reportSync(_ error: any Error, _ title: String) {
        guard (error as? CoreError)?.status == 404 else { app?.report(error, title); return }
        #if os(macOS)
        NSSound.beep()
        #endif
        notices.note(error.localizedDescription)
    }
}
