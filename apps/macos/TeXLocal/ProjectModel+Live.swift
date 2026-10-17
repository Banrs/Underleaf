import AppKit

/// Live Preview, which the session runs (`TeXpressoSession` shows its state), and SyncTeX between the source and either PDF.
extension ProjectModel {
    // MARK: - Live preview

    func startTeXpresso() {
        guard !closed, let session, texpresso.canStart else { return }
        texpresso.starting()
        if let pages = pdf.visiblePages { liveView(pages) }
        liveCaret()
        // TeXpresso's own window, which draws with MuPDF, is the fallback Settings offers.
        core.send("session_live_start", ["session": session, "window": LiveViewer.current == .window])
    }

    func stopTeXpresso() {
        guard let session else { return }
        texpresso.stopping()
        Task {
            if let state = try? await core.call("session_live_stop", ["session": session], as: LiveState.self) { texpresso.stopped(state) }
        }
        // Its pages go now, not as its stop ends.
        Task { await endLivePDF() }
    }

    func liveView(_ pages: ClosedRange<Int>) {
        guard texpresso.active, let session else { return }
        core.send("session_live_view", ["session": session, "first": pages.lowerBound, "last": pages.upperBound])
    }

    /// Told as it moves; the session tells TeXpresso where it settles.
    func liveCaret() {
        guard texpresso.active, let session, let path = editor.path else { return }
        core.send("session_live_caret", ["session": session, "path": path, "offset": editor.textView.selectedRange().location])
    }

    /// The build's PDF, or none, in place of the live one once Live Preview has stopped.
    func endLivePDF() async {
        guard livePDF, !texpresso.active, !(await showBuildPDF(buildPDF?.path(percentEncoded: false), replacingLive: true)), livePDF,
              !texpresso.active, !closed else { return }
        shown = .none
        pdf.clear()
    }

    /// The session's state. A run's PDFs start afresh: the session runs none between one run's end and the next's start.
    func liveChanged(_ state: LiveState) {
        texpresso.receive(state)
        if state.phase != .running { pdf.endLiveRun() }
    }

    /// A live PDF as `Core` read it where the event arrived, in the order the session sent them. A page is drawn over its
    /// own run's document only, never over the build's or the last run's.
    func showLive(_ read: LiveRead) {
        guard texpresso.active, !closed else { return }
        if case .document(let live?) = read {
            if !livePDF, app?.showPDF == false { app?.showPDF = true }
            shown = .live(live.url)
        }
        pdf.showLive(read)
    }

    // MARK: - SyncTeX

    func forwardSync(quietly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column) = (editor.currentLine, editor.currentColumn)
        let live = livePDF, args = syncArguments(["id": id, "file": path, "line": line, "column": column])
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            // Only on the pages it was found in: a rebuild may have moved it.
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

    /// With the click, the core finds the clicked word in the source lines round SyncTeX's.
    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil) async {
        await restart(&syncTask) { [self] in
            do {
                // A nil click bridges as null, which the core reads as none.
                let args = syncArguments(["id": id, "page": page, "x": x, "y": y, "text": click?.text, "at": click?.at])
                let loc = try await core.call("synctex_inverse", args, as: InverseLoc.self)
                guard !Task.isCancelled, !closed else { return }
                await open(loc.file, line: loc.line, column: loc.column)
            } catch {
                if !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Spot in the Source") }
            }
        }.value
    }

    /// A SyncTeX search that finds no match is ordinary (a comment, the preamble, a figure); anything else is a failure to explain.
    private func reportSync(_ error: any Error, _ title: String) {
        guard (error as? CoreError)?.status == 404 else { return report(error, title) }
        NSSound.beep()
        notices.note(error.localizedDescription)
    }
}
