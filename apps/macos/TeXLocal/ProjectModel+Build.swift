import Accessibility
import AppKit
import PDFKit

/// Builds, their PDF and their issues: the session builds, and its `build`, `build_finished` and `build_cleaned` events
/// say how it went (docs/core-api.md).
extension ProjectModel {
    // MARK: - The build's PDF

    /// The build's PDF at `path`, if it has one. A no-op build's PDF is already shown: reopening every page would lose
    /// PDFKit's state. True too when a newer load took over, which has the pane from then on.
    @discardableResult func showBuildPDF(_ path: String?, reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        await restart(&pdfLoad) { [self] in
            guard let path, !closed else { return false }
            let url = URL(filePath: path)
            // A live PDF stays only while Live Preview runs: once Stop is clicked, a build's PDF can take its place.
            var live: Bool { texpresso.active && (replacingLive || livePDF) }
            if live {
                buildPDF = FileManager.default.fileExists(atPath: path) ? url : nil
                return true
            }
            if !reloadIfUnchanged, shown == .build(url) { return true }
            let document = await PDFController.loadDocument(url)
            if Task.isCancelled { return true }
            guard let document, !closed, !live else { return false }
            buildPDF = url
            shown = .build(url)
            pdf.show(document)
            return true
        }.value
    }

    // MARK: - Compile

    /// The session queues one more during a build, and leaves an automatic one while Live Preview runs.
    /// A build asked for shows as one at once, so the toolbar has Stop from the click on and a Stop reaches the session
    /// behind it, where it ends the build however soon it comes; the core's `build` events then confirm or end it. An
    /// automatic one waits for them, as the core may leave it.
    func compile(auto: Bool = false) async {
        guard let session, !closed, app?.tex?.available == true else { return }
        if !auto, !compiling {
            compiling = true
            AccessibilityNotification.Announcement(String(localized: "Compiling")).post()
        }
        let sent: Void? = await alerting(String(localized: "“\((openPath ?? id).fileName)” Wasn’t Saved")) {
            try await core.call("session_compile", ["session": session, "auto": auto])
        }
        // The core has ended a build whose save failed, and with no core none started.
        if sent == nil { compiling = false }
    }

    func stopCompile() {
        guard compiling, let session else { return }
        core.send("session_stop_compile", ["session": session])
    }

    func cleanBuildFolder() async {
        guard let session, !closed else { return }
        let cleaned: Void? = await alerting("Couldn’t Clean the Build Folder") {
            try await core.call("session_clean", ["session": session])
        }
        guard cleaned != nil else { return }
        await inOrder { self.buildCleaned() }.value
    }

    func buildChanged(_ state: BuildState) {
        // Not through `notices.announce`: the result of a short build isn't held back for it. A build asked for here
        // has been announced already (`compile`).
        if state.compiling, !compiling, !state.auto { AccessibilityNotification.Announcement(String(localized: "Compiling")).post() }
        (compiling, outdated) = (state.compiling, state.outdated)
    }

    func buildFinished(_ finished: BuildFinished) async {
        let result = finished.result
        if let pdf = result.pdf, !closed {
            await showBuildPDF(pdf, reloadIfUnchanged: result.pdfChanged)
            // Not after typing through the build: the PDF hasn't the caret's text yet, and the sync would save it mid-word and start the next build at once.
            if result.ok, !finished.outdated, app?.showPDF == true, isLaTeX, UserDefaults.standard.bool(forKey: DefaultsKey.syncAfterCompile) {
                Task { await forwardSync(quietly: true) }
            }
        }
        guard !closed else { return }
        (self.result, outdated, chosenIssue) = (result, finished.outdated, nil)
        finishedBuilds += 1
        if !finished.auto {
            finishedManualBuild(result)
        } else if finished.announce {
            announceResult(result, queued: true)
        }
    }

    func buildCleaned() {
        guard !closed else { return }
        pdfLoad?.cancel()
        buildPDF = nil
        // A live PDF stays while Live Preview runs; once it has ended, the load it was waiting for is gone with the build.
        if !livePDF || !texpresso.active {
            shown = .none
            pdf.clear()
        }
        (result, chosenIssue, outdated) = (nil, nil, false)
    }

    private func finishedManualBuild(_ result: CompileResult) {
        if result.failed {
            panel.openForFailedBuild()
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        } else if result.ok, issues.isEmpty {
            panel.closeAfterCleanBuild()
        }
        announceResult(result)
    }

    private func announceResult(_ result: CompileResult, queued: Bool = false) {
        if result.failed {
            notices.announce(errorCount == 0 ? String(localized: "Build failed")
                     : String(AttributedString(localized: "Build failed, ^[\(errorCount) error](inflect: true)").characters), queued: queued)
        } else if result.ok {
            notices.announce(String(localized: "Build succeeded"), queued: queued)
        }
    }

    // MARK: - Issues

    func chooseIssue(_ place: Int?, focus: Bool, open: Bool = true) {
        chosenIssue = place
        if let session { core.send("session_choose_issue", ["session": session, "index": place]) }
        let issues = issues
        guard open, let place, issues.indices.contains(place), let file = issues[place].file else { return }
        Task { await self.open(file, line: issues[place].line, focus: focus) }
    }

    func goToIssue(next: Bool) {
        guard let session else { return }
        Task {
            guard let chosen = try? await core.call("session_issue", ["session": session, "next": next], as: ChosenIssue?.self),
                  !closed else { return }
            panel.show(.issues)
            chosenIssue = chosen.index
            if let file = chosen.issue.file { await open(file, line: chosen.issue.line, focus: true) }
        }
    }
}
