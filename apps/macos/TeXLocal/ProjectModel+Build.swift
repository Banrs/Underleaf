import AppKit

/// Builds, their PDF and their issues: the session builds, and its `build`, `build_finished` and `build_cleaned` events
/// say how it went (docs/core-api.md).
extension ProjectModel {
    // MARK: - The build's PDF

    /// The build's PDF at `path`, if it has one. A no-op build's PDF is already shown: reopening every page would lose
    /// PDFKit's state.
    @discardableResult func showBuildPDF(_ path: String?, reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        await restart(&pdfLoad) { [self] in
            guard let path, !closed else { return false }
            let url = URL(filePath: path)
            var live: Bool { replacingLive ? texpresso.active : livePDF }
            if live {
                buildPDF = FileManager.default.fileExists(atPath: path) ? url : nil
                return true
            }
            if !reloadIfUnchanged, shown == .build(url) { return true }
            guard let document = await PDFController.loadDocument(url), !Task.isCancelled, !closed, !live else { return false }
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
        guard let session, !closed, texAvailable else { return }
        if !auto, !compiling {
            compiling = true
            AccessibilityNotification.Announcement(String(localized: "Compiling")).post()
        }
        do {
            try await core.call("session_compile", ["session": session, "auto": auto])
        } catch {
            // The core has ended a build whose save failed, and with no core none started.
            compiling = false
            if !closed { report(error, String(localized: "“\((openPath ?? id).fileName)” Wasn’t Saved")) }
        }
    }

    func stopCompile() {
        guard compiling, let session else { return }
        core.send("session_stop_compile", ["session": session])
    }

    func cleanBuildFolder() async {
        guard let session, !closed else { return }
        do {
            try await core.call("session_clean", ["session": session])
        } catch {
            if !closed { report(error, "Couldn’t Clean the Build Folder") }
            return
        }
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
        if !livePDF {
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
