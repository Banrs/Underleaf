import SwiftUI
import UniformTypeIdentifiers

enum MenuCommand: CaseIterable {
    case projectNew, projectOpen, openQuickly, projectClose, projectExport, projectExportArxiv, projectSearch
    case fileNew, fileNewFolder, fileUpload, fileSave, fileSaveVersion, fileBrowseVersions, pdfSave, pdfOpen, filePrint
    case editBold, editItalic, editUnderline, editMath, editComment, editShiftRight, editShiftLeft, editMoveLineUp, editMoveLineDown
    case editDuplicateLine, editDeleteLine, editGotoLine, goBack, goForward, jumpToDefinition, findUsages, quickHelp, editRename
    case editFold, editUnfold, editFoldAll, editUnfoldAll, symbolLibrary
    case pdfFind, pdfGotoPage
    case viewToggleSource, viewTogglePDF, viewToggleInspector, viewToggleLogs, viewToggleWordCount
    case viewZoomIn, viewZoomOut, viewActualSize, viewFitWidth, viewFitPage
    case compileRun, compileStop, compileClean, syncForward, syncInverse, issueNext, issuePrevious

    var title: String { spec.title }
    var shortcut: KeyboardShortcut? { spec.shortcut }

    private var spec: (title: String, shortcut: KeyboardShortcut?) {
        switch self {
        case .projectNew: ("New Project…", KeyboardShortcut("n", modifiers: [.command, .shift]))
        case .projectOpen: ("Open…", KeyboardShortcut("o"))
        case .openQuickly: ("Open Quickly…", KeyboardShortcut("o", modifiers: [.command, .shift]))
        case .projectClose: ("Close Project", KeyboardShortcut("w", modifiers: [.command, .shift]))
        case .projectExport: ("Export Project as ZIP…", nil)
        case .projectExportArxiv: ("Export for arXiv…", nil)
        case .projectSearch: ("Find in Project…", KeyboardShortcut("f", modifiers: [.command, .shift]))
        case .fileNew: ("New File", KeyboardShortcut("n"))
        case .fileNewFolder: ("New Folder", KeyboardShortcut("n", modifiers: [.command, .shift, .option]))
        case .fileUpload: ("Add Files…", nil)
        case .fileSave: ("Save", KeyboardShortcut("s"))
        case .fileSaveVersion: ("Save Version…", nil)
        case .fileBrowseVersions: ("Browse Version History…", KeyboardShortcut("h", modifiers: [.command, .option, .control]))
        case .pdfSave: ("Export as PDF…", nil)
        case .pdfOpen: ("Open PDF in Default App", KeyboardShortcut("o", modifiers: [.command, .option]))
        case .filePrint: ("Print…", KeyboardShortcut("p"))
        case .editBold: ("Bold", KeyboardShortcut("b"))
        case .editItalic: ("Italic", KeyboardShortcut("i"))
        case .editUnderline: ("Underline", KeyboardShortcut("u"))
        case .editMath: ("Inline Math", KeyboardShortcut("e", modifiers: [.command, .option]))
        case .editComment: ("Comment Selection", KeyboardShortcut("/"))
        case .editShiftRight: ("Shift Right", KeyboardShortcut("]"))
        case .editShiftLeft: ("Shift Left", KeyboardShortcut("["))
        case .editMoveLineUp: ("Move Line Up", KeyboardShortcut(.upArrow, modifiers: [.command, .control]))
        case .editMoveLineDown: ("Move Line Down", KeyboardShortcut(.downArrow, modifiers: [.command, .control]))
        case .editDuplicateLine: ("Duplicate Line", KeyboardShortcut("d"))
        case .editDeleteLine: ("Delete Line", KeyboardShortcut("k", modifiers: [.control, .shift]))
        case .editGotoLine: ("Go to Line…", KeyboardShortcut("l"))
        case .editFold: ("Fold", KeyboardShortcut(.leftArrow, modifiers: [.command, .option]))
        case .editUnfold: ("Unfold", KeyboardShortcut(.rightArrow, modifiers: [.command, .option]))
        case .editFoldAll: ("Fold All", KeyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift]))
        case .editUnfoldAll: ("Unfold All", KeyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift]))
        case .goBack: ("Go Back", KeyboardShortcut(.leftArrow, modifiers: [.command, .control]))
        case .goForward: ("Go Forward", KeyboardShortcut(.rightArrow, modifiers: [.command, .control]))
        case .jumpToDefinition: ("Jump to Definition", KeyboardShortcut("j", modifiers: [.command, .control]))
        case .findUsages: ("Find Usages", KeyboardShortcut("f", modifiers: [.command, .control, .shift]))
        case .quickHelp: ("Quick Help for Selected Item", KeyboardShortcut("?", modifiers: [.command, .control]))
        case .editRename: ("Rename…", nil)
        case .symbolLibrary: ("Symbol Library…", KeyboardShortcut("l", modifiers: [.command, .shift]))
        case .pdfFind: ("Find in PDF…", nil)
        case .pdfGotoPage: ("Go to Page…", KeyboardShortcut("g", modifiers: [.command, .option]))
        case .viewToggleSource: ("Source", KeyboardShortcut("s", modifiers: [.command, .option]))
        case .viewTogglePDF: ("PDF", KeyboardShortcut("p", modifiers: [.command, .option]))
        case .viewToggleInspector: ("Inspector", KeyboardShortcut("i", modifiers: [.command, .option]))
        case .viewToggleLogs: ("Logs", KeyboardShortcut("y", modifiers: [.command, .shift]))
        case .viewToggleWordCount: ("Word Count", nil)
        case .viewZoomIn: ("Zoom In", KeyboardShortcut("="))
        case .viewZoomOut: ("Zoom Out", KeyboardShortcut("-"))
        case .viewActualSize: ("Actual Size", KeyboardShortcut("0"))
        case .viewFitWidth: ("Fit Width", KeyboardShortcut("9"))
        case .viewFitPage: ("Fit Page", KeyboardShortcut("9", modifiers: [.command, .option]))
        case .compileRun: ("Compile", KeyboardShortcut(.return))
        case .compileStop: ("Stop", KeyboardShortcut("."))
        case .compileClean: ("Clean Build Folder", KeyboardShortcut("k", modifiers: [.command, .shift]))
        case .syncForward: ("Go to PDF Position", KeyboardShortcut("j", modifiers: [.command, .option]))
        case .syncInverse: ("Go to Source Position", nil)
        case .issueNext: ("Go to Next Issue", KeyboardShortcut("'"))
        case .issuePrevious: ("Go to Previous Issue", KeyboardShortcut("\""))
        }
    }

    var editsSelection: Bool {
        switch self {
        case .editBold, .editItalic, .editUnderline, .editMath, .editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp,
             .editMoveLineDown, .editDuplicateLine, .editDeleteLine, .jumpToDefinition, .findUsages, .quickHelp, .editRename,
             .editFold, .editUnfold, .editFoldAll, .editUnfoldAll: true
        default: false
        }
    }

    var action: Action? {
        switch self {
        case .editBold: .edit(.bold)
        case .editItalic: .edit(.italic)
        case .editUnderline: .edit(.underline)
        case .editMath: .edit(.math)
        case .editComment: .edit(.comment)
        case .editMoveLineUp: .edit(.moveLineUp)
        case .editMoveLineDown: .edit(.moveLineDown)
        case .editDuplicateLine: .edit(.duplicateLine)
        case .editDeleteLine: .edit(.deleteLine)
        case .editFold: .edit(.fold)
        case .editUnfold: .edit(.unfold)
        case .editFoldAll: .edit(.foldAll)
        case .editUnfoldAll: .edit(.unfoldAll)
        case .pdfFind: .pdf(.find)
        case .viewZoomIn: .pdf(.zoomIn)
        case .viewZoomOut: .pdf(.zoomOut)
        case .viewActualSize: .pdf(.actualSize)
        case .viewFitWidth: .pdf(.fitWidth)
        case .viewFitPage: .pdf(.fitPage)
        case .syncInverse: .pdf(.inverseFromView)
        default: nil
        }
    }

    enum Action { case edit(EditorCommand), pdf(PDFAction) }

    var style: (symbol: String, help: String)? {
        switch self {
        case .editBold: ("bold", String(localized: "Make text bold"))
        case .editItalic: ("italic", String(localized: "Make text italic"))
        case .editUnderline: ("underline", String(localized: "Underline text"))
        default: nil
        }
    }
}

enum Prompt: Identifiable, Hashable {
    case gotoLine, gotoPage, rename(SymbolName), saveVersion, versionHistory

    var id: Self { self }
}

struct NewEntry: Equatable {
    var directory: Bool
    var folder: String?
}

struct ItemActions {
    let rename: (() -> Void)?
    let showInFinder: () -> Void
    let moveToTrash: (() -> Void)?
}

enum PDFAction {
    case zoomIn, zoomOut, actualSize, fitWidth, fitPage, goToPage(Int), find, inverseFromView
    case reveal(ForwardLoc, SyncSource?)
}

extension AppModel {
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        guard project?.isOpen != false else { return false }
        return switch command {
        case .projectNew, .projectOpen: libraryProblem == nil
        case .fileSave, .editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp, .editMoveLineDown, .editDuplicateLine, .editDeleteLine,
             .editGotoLine, .jumpToDefinition, .findUsages, .quickHelp, .editFold, .editUnfold, .editFoldAll, .editUnfoldAll:
            project?.editsText == true
        case .goBack, .goForward: project?.canRetrace(back: command == .goBack) ?? false
        case .editBold, .editItalic, .editUnderline, .editMath: project?.isLaTeX == true
        case .editRename: project.map { $0.editsText && $0.views?.validates(command) == true } ?? false
        case .compileRun: tex?.available == true && project?.compiling == false
        case .compileStop: project?.compiling == true
        case .viewZoomIn, .viewZoomOut: project.map { $0.hasPDF && $0.views?.validates(command) == true } ?? false
        case .pdfSave, .pdfOpen, .filePrint: project?.buildPDF != nil
        case .pdfFind, .pdfGotoPage, .viewActualSize, .viewFitWidth, .viewFitPage, .syncInverse:
            project?.hasPDF == true
        case .syncForward: project?.canSyncForward() == true
        case .issueNext, .issuePrevious: project?.issues.contains { $0.file != nil } == true
        case .symbolLibrary: true
        default: project != nil
        }
    }

    func isEnabledInMenuBar(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        isEnabled(command, on: project) && (!command.editsSelection || project?.sourceHasKeyboard == true)
    }

    func shortcut(_ command: MenuCommand, on project: ProjectModel?) -> KeyboardShortcut? {
        switch (command, project) {
        case (.projectNew, nil): MenuCommand.fileNew.shortcut
        case (.fileNew, nil): nil
        default: command.shortcut
        }
    }

    var canPreviewLive: Bool { tex?.texpresso != nil }
}

extension WindowModel {
    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        if command == .pdfOpen, let name = app.pdfAppName { return "Open PDF in \(name)" }
        let shown: Bool? = switch command {
        case .viewToggleSource: showSource
        case .viewTogglePDF: showPDF
        case .viewToggleInspector: project?.views?.inspectorShown ?? false
        case .viewToggleLogs: project?.panel.shown == true
        case .viewToggleWordCount: app.showWordCount
        default: nil
        }
        return shown.map { "\($0 ? "Hide" : "Show") \(command.title)" } ?? command.title
    }

    func perform(_ command: MenuCommand, on project: ProjectModel?) {
        guard app.isEnabled(command, on: project) else { return }
        switch command.action {
        case .edit(let edit)?: project?.views?.perform(edit)
        case .pdf(let action)?: requestPDF(action)
        case nil: break
        }
        switch command {
        case .projectNew: newProject()
        case .projectOpen: openingProject = true
        case .projectClose: Task { if await close() { app.showHome() } }
        case .projectExport, .projectExportArxiv:
            let arxiv = command == .projectExportArxiv
            if let project {
                exporting = ExportFile(name: arxiv ? "\(project.name) arXiv.zip" : "\(project.name).zip", type: .zip) {
                    try await project.exportZip(forArxiv: arxiv)
                }
            }
        case .projectSearch: controller?.focusSearch()
        case .fileNew, .fileNewFolder:
            project?.showNavigator(.files)
            newEntry = NewEntry(directory: command == .fileNewFolder)
        case .fileUpload: addingFiles = true
        case .fileSave: Task { await project?.save() }
        case .fileSaveVersion: prompt = .saveVersion
        case .pdfSave: if let project, let url = project.buildPDF { exporting = ExportFile(name: "\(project.name).pdf", type: .pdf) { url } }
        case .fileBrowseVersions: prompt = .versionHistory
        case .openQuickly, .pdfOpen, .viewToggleInspector, .quickHelp, .filePrint, .editShiftRight, .editShiftLeft, .jumpToDefinition,
             .findUsages, .editRename:
            project?.views?.perform(command)
        case .editGotoLine: prompt = .gotoLine
        case .goBack, .goForward: Task { await project?.retrace(back: command == .goBack) }
        case .pdfGotoPage: prompt = .gotoPage
        case .viewToggleSource: toggleSource()
        case .viewTogglePDF: togglePDF()
        case .viewToggleLogs: project?.panel.shown.toggle()
        case .viewToggleWordCount: app.showWordCount.toggle()
        case .compileRun: Task { await project?.compile() }
        case .compileStop: project?.stopCompile()
        case .compileClean: Task { await project?.cleanBuildFolder() }
        case .syncForward: Task { await project?.forwardSync() }
        case .issueNext: project?.goToIssue(next: true)
        case .issuePrevious: project?.goToIssue(next: false)
        case .symbolLibrary: SymbolLibrary.toggle(app: app)
        default: break
        }
    }
}

struct EnginePicker: View {
    let project: ProjectModel?

    var body: some View {
        Picker("Engine", selection: project.map { Bindable($0).engine } ?? .constant(nil)) {
            ForEach(Engine.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        .disabled(project?.engine == nil)
    }
}
