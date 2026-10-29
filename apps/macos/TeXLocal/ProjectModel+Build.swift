import Accessibility
import AppKit
import PDFKit

extension ProjectModel {
    @discardableResult func showPDF() -> Task<Void, Never> {
        restart(&pdfLoad) { [self] in
            guard let shown = store.shownPdf, !shown.live else { return }
            let document: PDFDocument? = if let path = shown.path { await PDFController.loadDocument(URL(filePath: path)) } else { nil }
            guard !Task.isCancelled, !closed else { return }
            if let document { pdf.show(document) } else { pdf.clear() }
            hasPDF = document != nil
        }
    }

    func showIssues() {
        guard let path = editor.path else { return }
        editor.textView.issues.lines = store.build?.lines[path]?.byLine ?? [:]
        editor.textView.issues.live = store.live?.lines[path]?.byLine ?? [:]
    }

    func compile() async {
        guard let session, !closed, app?.tex?.available == true else { return }
        await alerting(notSavedTitle()) { try await session.call(Compile(auto: false)) }
    }

    func stopCompile() {
        guard compiling, let session else { return }
        session.send(StopCompile())
    }

    func cleanBuildFolder() async {
        guard let session, !closed else { return }
        await alerting("Couldn’t Clean the Build Folder") { try await session.call(Clean()) }
    }

    func buildChanged(_ build: BuildState, was: BuildState?) {
        let manual = { (build: BuildState?) in build?.compiling == true && build?.auto == false }
        if manual(build), !manual(was) { AccessibilityNotification.Announcement(String(localized: "Compiling")).post() }
        if build.listed != was?.listed { chosenIssue = nil }
        showIssues()
    }

    func buildFinished(_ finished: BuildFinished) {
        guard let result else { return }
        if result.ok, !outdated, app?.showPDF == true, isLaTeX, UserDefaults.standard.bool(forKey: DefaultsKey.syncAfterCompile) {
            Task { [pdfLoad] in
                await pdfLoad?.value
                await forwardSync(quietly: true)
            }
        }
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
