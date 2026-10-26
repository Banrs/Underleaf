import Accessibility
import AppKit
import PDFKit

extension ProjectModel {
    @discardableResult func showBuildPDF(_ path: String?, reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        await restart(&pdfLoad) { [self] in
            guard let path, !closed else { return false }
            let url = URL(filePath: path)
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

    func compile(auto: Bool = false) async {
        guard let session, !closed, app?.tex?.available == true else { return }
        if !auto, !compiling {
            compiling = true
            AccessibilityNotification.Announcement(String(localized: "Compiling")).post()
        }
        let sent: Void? = await alerting(notSavedTitle()) {
            try await core.call("session_compile", ["session": session, "auto": auto])
        }
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
        if state.compiling, !compiling, !state.auto { AccessibilityNotification.Announcement(String(localized: "Compiling")).post() }
        (compiling, outdated) = (state.compiling, state.outdated)
    }

    func buildFinished(_ finished: BuildFinished) async {
        let result = finished.result
        if let pdf = result.pdf, !closed {
            await showBuildPDF(pdf, reloadIfUnchanged: result.pdfChanged)
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
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
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
        let issues = listed
        guard open, let place, issues.indices.contains(place), let file = issues[place].file else { return }
        Task { await self.open(file, line: issues[place].line, focus: focus, jump: true) }
    }

    func goToIssue(next: Bool) {
        let places = issues.indices.filter { issues[$0].file != nil }
        let after = next ? places.first { $0 > chosenIssue ?? -1 } : places.last { $0 < chosenIssue ?? .max }
        guard let place = after ?? (next ? places.first : places.last) else { return }
        if panel.shown { panel.tab = .issues }
        chooseIssue(place, focus: true)
    }
}
