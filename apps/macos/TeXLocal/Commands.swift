import SwiftUI
import UniformTypeIdentifiers

enum MenuCommand: CaseIterable {
    case projectNew
    case projectOpen
    case projectClose
    case projectExport
    case projectSearch
    case fileNew
    case fileNewFolder
    case fileUpload
    case fileSave
    case pdfSave
    case filePrint
    case editBold
    case editItalic
    case editUnderline
    case editMath
    case editComment
    case editMoveLineUp
    case editMoveLineDown
    case editGotoLine
    case pdfFind
    case pdfGotoPage
    case viewToggleSidebar
    case viewTogglePdf
    case viewToggleInspector
    case viewToggleLogs
    case viewToggleWordCount
    case viewZoomIn
    case viewZoomOut
    case viewActualSize
    case viewFitWidth
    case viewFitPage
    case viewTextBigger
    case viewTextSmaller
    case compileRun
    case compileStop
    case compileClean
    case syncForward
    case syncInverse
    case issueNext
    case issuePrevious

    var title: String {
        switch self {
        case .projectNew: "New Project…"
        case .projectOpen: "Open…"
        case .projectClose: "Close Project"
        case .projectExport: "Export Project as ZIP…"
        case .projectSearch: "Find in Project…"
        case .fileNew: "New File"
        case .fileNewFolder: "New Folder"
        case .fileUpload: "Add Files…"
        case .fileSave: "Save"
        case .pdfSave: "Export as PDF…"
        case .filePrint: "Print…"
        case .editBold: "Bold"
        case .editItalic: "Italic"
        case .editUnderline: "Underline"
        case .editMath: "Inline Math"
        case .editComment: "Comment Selection"
        case .editMoveLineUp: "Move Line Up"
        case .editMoveLineDown: "Move Line Down"
        case .editGotoLine: "Go to Line…"
        case .pdfFind: "Find in PDF…"
        case .pdfGotoPage: "Go to Page…"
        case .viewToggleSidebar: "Sidebar"
        case .viewTogglePdf: "PDF"
        case .viewToggleInspector: "Inspector"
        case .viewToggleLogs: "Build Panel"
        case .viewToggleWordCount: "Word Count"
        case .viewZoomIn: "Zoom In"
        case .viewZoomOut: "Zoom Out"
        case .viewActualSize: "Actual Size"
        case .viewFitWidth: "Fit Width"
        case .viewFitPage: "Fit Page"
        case .viewTextBigger: "Make Text Bigger"
        case .viewTextSmaller: "Make Text Smaller"
        case .compileRun: "Compile"
        case .compileStop: "Stop"
        case .compileClean: "Clean Build Folder"
        case .syncForward: "Go to PDF Position"
        case .syncInverse: "Go to Source Position"
        case .issueNext: "Go to Next Issue"
        case .issuePrevious: "Go to Previous Issue"
        }
    }

    var symbol: String? {
        switch self {
        case .editBold: "bold"
        case .editItalic: "italic"
        case .editUnderline: "underline"
        default: nil
        }
    }

    /// ⌥⌘G is Go to Page, as in the Mac's PDF readers; Find in PDF… has none, as ⌘F finds in the PDF while it has the keyboard.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .projectNew: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .projectOpen: KeyboardShortcut("o")
        case .projectClose: KeyboardShortcut("w", modifiers: [.command, .shift])
        case .projectSearch: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .fileNew: KeyboardShortcut("n")
        case .fileNewFolder: KeyboardShortcut("n", modifiers: [.command, .shift, .option])
        case .fileSave: KeyboardShortcut("s")
        case .filePrint: KeyboardShortcut("p")
        case .editBold: KeyboardShortcut("b")
        case .editItalic: KeyboardShortcut("i")
        case .editUnderline: KeyboardShortcut("u")
        case .editMath: KeyboardShortcut("e", modifiers: [.command, .option])
        case .editComment: KeyboardShortcut("/")
        case .editMoveLineUp: KeyboardShortcut(.upArrow, modifiers: [.command, .control])
        case .editMoveLineDown: KeyboardShortcut(.downArrow, modifiers: [.command, .control])
        case .editGotoLine: KeyboardShortcut("l")
        case .pdfGotoPage: KeyboardShortcut("g", modifiers: [.command, .option])
        case .viewToggleSidebar: KeyboardShortcut("s", modifiers: [.command, .control])
        case .viewTogglePdf: KeyboardShortcut("p", modifiers: [.command, .option])
        case .viewToggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        case .viewToggleLogs: KeyboardShortcut("y", modifiers: [.command, .shift])
        case .viewZoomIn: KeyboardShortcut("=")
        case .viewZoomOut: KeyboardShortcut("-")
        case .viewActualSize: KeyboardShortcut("0")
        case .viewFitWidth: KeyboardShortcut("9")
        case .viewFitPage: KeyboardShortcut("9", modifiers: [.command, .option])
        case .compileRun: KeyboardShortcut(.return)
        case .compileStop: KeyboardShortcut(".")
        case .compileClean: KeyboardShortcut("k", modifiers: [.command, .shift])
        case .syncForward: KeyboardShortcut("j", modifiers: [.command, .option])
        case .issueNext: KeyboardShortcut("'")
        case .issuePrevious: KeyboardShortcut("\"")
        // ⌥⌘= and ⌥⌘− are the system's own screen zoom.
        case .pdfSave, .projectExport, .fileUpload, .pdfFind, .viewToggleWordCount, .viewTextBigger, .viewTextSmaller,
             .syncInverse: nil
        }
    }
}

enum Prompt: Identifiable, Hashable {
    case gotoLine, gotoPage

    var id: Self { self }
}

struct NewEntry: Equatable {
    var directory: Bool
    var folder: String?
}

enum PDFAction {
    case zoomIn, zoomOut, actualSize, fitWidth, fitPage, goToPage(Int), find, inverseFromView
    case reveal(ForwardLoc, SyncSource?)
}

extension AppModel {
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        switch command {
        case .projectNew, .projectOpen: libraryProblem == nil
        case .projectSearch: project != nil || (self.project == nil && mainWindowIsKey)
        case .fileSave, .editComment, .editMoveLineUp, .editMoveLineDown, .editGotoLine, .viewTextBigger, .viewTextSmaller:
            project?.editsText == true
        case .editBold, .editItalic, .editUnderline, .editMath: project?.isLaTeX == true
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .compileStop: project?.compiling == true
        case .viewZoomIn: project.map { $0.hasPDF && $0.pdf.canZoomIn } ?? false
        case .viewZoomOut: project.map { $0.hasPDF && $0.pdf.canZoomOut } ?? false
        case .pdfSave, .filePrint: project?.buildPDF != nil
        case .pdfFind, .pdfGotoPage, .viewActualSize, .viewFitWidth, .viewFitPage, .syncInverse:
            project?.hasPDF == true
        case .syncForward: project.map { $0.hasPDF && $0.isLaTeX } ?? false
        case .issueNext, .issuePrevious: project?.issues.contains { $0.file != nil } == true
        default: project != nil
        }
    }

    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        if command == .projectSearch, self.project == nil { return "Find Project…" }
        let shown: Bool? = switch command {
        case .viewToggleSidebar: sidebarShown
        case .viewTogglePdf: showPDF
        case .viewToggleInspector: inspectorShown
        case .viewToggleLogs: project?.panel.shown == true
        case .viewToggleWordCount: showWordCount
        default: nil
        }
        return shown.map { "\($0 ? "Hide" : "Show") \(command.title)" } ?? command.title
    }

    func shortcut(_ command: MenuCommand, on project: ProjectModel?) -> KeyboardShortcut? {
        switch (command, project) {
        case (.projectNew, nil): MenuCommand.fileNew.shortcut
        case (.fileNew, nil): nil
        default: command.shortcut
        }
    }

    func perform(_ command: MenuCommand, on project: ProjectModel?) {
        guard isEnabled(command, on: project) else { return }
        switch command {
        case .projectNew: newProject()
        case .projectOpen: openingProject = true
        case .projectClose: Task { await close() }
        case .projectExport:
            if let project { exporting = ExportFile(name: "\(project.id).zip", type: .zip, make: project.exportZip) }
        case .projectSearch:
            if project != nil { sidebarShown = true }
            searchFocusToken += 1
        case .fileNew, .fileNewFolder:
            sidebarShown = true
            newEntry = NewEntry(directory: command == .fileNewFolder)
        case .fileUpload: addingFiles = true
        case .fileSave: Task { await project?.save() }
        case .pdfSave:
            if let project, let url = project.buildPDF {
                exporting = ExportFile(name: "\(project.id).pdf", type: .pdf) { url }
            }
        // The PDF, not the first responder (usually the source), and whether or not its pane shows.
        case .filePrint:
            if let project { project.pdf.print(title: project.id) }
        case .editBold: project?.editor.perform(.bold)
        case .editItalic: project?.editor.perform(.italic)
        case .editUnderline: project?.editor.perform(.underline)
        case .editMath: project?.editor.perform(.math)
        case .editComment: project?.editor.perform(.comment)
        case .editMoveLineUp: project?.editor.perform(.moveLineUp)
        case .editMoveLineDown: project?.editor.perform(.moveLineDown)
        case .editGotoLine: prompt = .gotoLine
        case .pdfGotoPage: prompt = .gotoPage
        case .pdfFind: requestPDF(.find)
        case .viewToggleSidebar: sidebarShown.toggle()
        case .viewTogglePdf: togglePDF()
        case .viewToggleInspector: inspectorShown.toggle()
        case .viewToggleLogs: project?.panel.shown.toggle()
        case .viewToggleWordCount: showWordCount.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewActualSize: requestPDF(.actualSize)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitPage: requestPDF(.fitPage)
        case .viewTextBigger: EditorPrefs.stepFontSize(by: 1)
        case .viewTextSmaller: EditorPrefs.stepFontSize(by: -1)
        case .compileRun: Task { await project?.compile() }
        case .compileStop: project?.stopCompile()
        case .compileClean: Task { await project?.cleanBuildFolder() }
        case .syncForward: Task { await project?.forwardSync() }
        case .syncInverse: requestPDF(.inverseFromView)
        case .issueNext: project?.goToIssue(next: true)
        case .issuePrevious: project?.goToIssue(next: false)
        }
    }

    var canPreviewLive: Bool { tex?.texpresso != nil }
}

struct AppCommands: Commands {
    let app: AppModel
    private var project: ProjectModel? { app.commandProject }

    private func item(_ command: MenuCommand) -> some View {
        CommandItem(app: app, command: command)
    }

    private func items(_ commands: [MenuCommand]) -> some View {
        ForEach(commands, id: \.self) { item($0) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items([.projectNew, .fileNew, .fileNewFolder])
            item(.projectOpen)
            Menu("Open Recent") {
                ForEach(app.recents) { recent in
                    Button {
                        Task { await app.open(recent.id) }
                    } label: {
                        Label(recent.name, systemImage: "text.document")
                    }
                    // macOS 27 hides a menu item's image unless the label style shows it.
                    .labelStyle(.titleAndIcon)
                }
                Divider()
                Button("Clear Menu") { app.recentProjects = [] }
                    .disabled(app.recents.isEmpty)
            }
            Divider()
            item(.fileUpload)
        }
        CommandGroup(after: .saveItem) {
            item(.fileSave)
            Divider()
            item(.projectClose)
            Divider()
            ItemMenuItems(actions: app.mainWindowIsKey ? app.chosenItem : nil, trashShortcut: KeyboardShortcut(.delete))
                .labelStyle(.titleAndIcon)
        }
        CommandGroup(replacing: .importExport) {
            items([.pdfSave, .projectExport])
            Divider()
            if let project, let url = project.buildPDF {
                ShareLink(item: url)
            } else {
                Button {} label: { Label("Share…", systemImage: "square.and.arrow.up") }.labelStyle(.titleAndIcon).disabled(true)
            }
        }
        CommandGroup(replacing: .printItem) {
            item(.filePrint)
        }
        // A replacement group would lose the spelling and substitution checkmarks.
        TextEditingCommands()
        CommandGroup(before: .textEditing) {
            items([.projectSearch, .pdfFind])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            items([.editComment, .editMoveLineUp, .editMoveLineDown])
        }
        CommandGroup(replacing: .textFormatting) {
            items([.editBold, .editItalic, .editUnderline])
            Divider()
            Menu("Section Level") { SectionLevelItems(project: project) }
                .disabled(project?.isLaTeX != true)
        }
        CommandGroup(replacing: .sidebar) {
            item(.viewToggleSidebar)
            Button(app.outlineCollapsed || project?.isLaTeX != true ? "Show File Outline" : "Hide File Outline") {
                app.outlineCollapsed.toggle()
            }
                .disabled(project?.isLaTeX != true || project?.search.isSearching == true || !app.sidebarShown)
            items([.viewTogglePdf, .viewToggleInspector, .viewToggleLogs, .viewToggleWordCount])
            Divider()
            items([.viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitPage])
            Divider()
            items([.viewTextBigger, .viewTextSmaller])
        }
        CommandMenu("Go") {
            items([.editGotoLine, .pdfGotoPage])
            Divider()
            items([.syncForward, .syncInverse])
            Divider()
            items([.issueNext, .issuePrevious])
        }
        CommandMenu("Insert") {
            Group {
                MathMenuItems(project: project, shortcut: MenuCommand.editMath.shortcut) {
                    app.perform(.editMath, on: project)
                }
                Divider()
                InsertMenuItems(project: project)
            }
            .disabled(project?.isLaTeX != true)
        }
        CommandMenu("Compile") {
            items([.compileRun, .compileStop, .compileClean])
            Divider()
            Toggle("Compile Automatically", isOn: Bindable(app).autoCompile)
            LivePreviewItem(app: app)
            Divider()
            EnginePicker(project: project)
            SetMainFileItem(app: app)
        }
    }
}

/// A menu item of its own, so a change to what it shows re-evaluates it and not the whole menu bar.
private struct CommandItem: View {
    let app: AppModel
    let command: MenuCommand

    var body: some View {
        let project = app.commandProject
        Button { app.perform(command, on: project) } label: {
            let title = app.title(command, on: project)
            // macOS 27 shows a menu item's image only with this style.
            if let symbol = command.symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .labelStyle(.titleAndIcon)
        // ⌘N follows whether a project is open, not which window is key.
        .keyboardShortcut(app.shortcut(command, on: app.project))
        .disabled(!app.isEnabled(command, on: project))
    }
}

private struct LivePreviewItem: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        Toggle("Live Preview", isOn: Binding(
            get: { project?.texpresso.active == true },
            set: { $0 ? project?.startTeXpresso() : project?.stopTeXpresso() }))
            .disabled(!app.canPreviewLive || project.map { !$0.initialLoadComplete || $0.texpresso.phase == .stopping } ?? true)
    }
}

private struct SetMainFileItem: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        Button("Set as Main File") {
            if let project, let path = project.openPath { Task { await project.setMainFile(path) } }
        }
        .disabled(project?.isLaTeX != true || project?.openPath == project?.settings?.mainFile)
    }
}
