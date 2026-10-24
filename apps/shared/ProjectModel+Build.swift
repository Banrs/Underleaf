import Accessibility
#if os(macOS)
import AppKit
#endif
import PDFKit

/// Builds, their PDF and their issues, as the session's build events tell them (docs/core-api.md).
extension ProjectModel {
    /// A no-op build's PDF is already shown: reopening it would lose PDFKit's state. True too when a newer load took over.
    @discardableResult func showBuildPDF(_ path: String?, reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        await restart(&pdfLoad) { [self] in
            guard let path, !closed else { return false }
            let url = URL(filePath: path)
            // A live PDF stays while Live Preview runs.
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
            #if os(iOS)
            // Builds are remade from the sources, so the iPad's backup leaves them out.
            var build = url.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? build.setResourceValues(values)
            #endif
            shown = .build(url)
            pdf.show(document)
            return true
        }.value
    }

    /// A build asked for shows at once, so the toolbar has Stop from the click on; an automatic one waits for the session's
    /// events, as the session leaves one while Live Preview runs.
    func compile(auto: Bool = false) async {
        guard let session, !closed, app?.tex?.available == true else { return }
        if !auto, !compiling {
            compiling = true
            AccessibilityNotification.Announcement(String(localized: "Compiling")).post()
        }
        let sent: Void? = await alerting(notSavedTitle()) {
            try await core.call("session_compile", ["session": session, "auto": auto])
        }
        // The core has ended a build whose save failed.
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
        // Not through `notices`, which would hold back a short build's result.
        if state.compiling, !compiling, !state.auto { AccessibilityNotification.Announcement(String(localized: "Compiling")).post() }
        (compiling, outdated) = (state.compiling, state.outdated)
    }

    func buildFinished(_ finished: BuildFinished) async {
        let result = finished.result
        if let pdf = result.pdf, !closed {
            await showBuildPDF(pdf, reloadIfUnchanged: result.pdfChanged)
            // Not after typing through the build: the sync would save mid-word and start the next build at once.
            if result.ok, !finished.outdated, app?.showPDF == true, isLaTeX, UserDefaults.standard.bool(forKey: DefaultsKey.syncAfterCompile) {
                Task { await forwardSync(quietly: true) }
            }
        }
        guard !closed else { return }
        (self.result, outdated, chosenIssue) = (result, finished.outdated, nil)
        finishedBuilds += 1
        if !finished.auto {
            if result.failed {
                panel.openForFailedBuild()
                #if os(macOS)
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
                #endif
            } else if result.ok, issues.isEmpty {
                panel.closeAfterCleanBuild()
            }
            announceResult(result)
        } else if finished.announce {
            announceResult(result, queued: true)
        }
    }

    func buildCleaned() {
        guard !closed else { return }
        pdfLoad?.cancel()
        buildPDF = nil
        // A live PDF stays while Live Preview runs.
        if !livePDF || !texpresso.active {
            shown = .none
            pdf.clear()
        }
        (result, chosenIssue, outdated) = (nil, nil, false)
    }

    private func announceResult(_ result: CompileResult, queued: Bool = false) {
        if result.failed {
            notices.announce(errorCount == 0 ? String(localized: "Build failed")
                     : String(AttributedString(localized: "Build failed, ^[\(errorCount) error](inflect: true)").characters), queued: queued)
        } else if result.ok {
            notices.announce(String(localized: "Build succeeded"), queued: queued)
        }
    }

    func chooseIssue(_ place: Int?, focus: Bool, open: Bool = true) {
        chosenIssue = place
        if let session { core.send("session_choose_issue", ["session": session, "index": place]) }
        let issues = listed
        guard open, let place, issues.indices.contains(place), let file = issues[place].file else { return }
        Task { await self.open(file, line: issues[place].line, focus: focus, jump: true) }
    }

    func goToIssue(next: Bool) {
        guard let session else { return }
        Task {
            guard let chosen = try? await core.call("session_issue", ["session": session, "next": next], as: ChosenIssue?.self),
                  !closed else { return }
            panel.show(.issues)
            chosenIssue = chosen.index
            if let file = chosen.issue.file { await open(file, line: chosen.issue.line, focus: true, jump: true) }
        }
    }
}
