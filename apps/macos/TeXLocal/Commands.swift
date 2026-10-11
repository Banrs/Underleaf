import SwiftUI

/// The app's commands and their key equivalents.
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

    /// The toggles' titles name what they show; the menus say Show or Hide (`AppModel.title`).
    var title: String {
        switch self {
        case .projectNew: "New Project…"
        case .projectOpen: "Open…"
        case .projectClose: "Close Project"
        case .projectExport: "Export Project as ZIP…"
        case .projectSearch: "Find in Project…"
        // No ellipsis: the name is typed in place, as in Finder's New Folder (HIG, Menus).
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
        // Safari's names for them, beside its Zoom In and Zoom Out.
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

    /// Menus carry icons for a whole group or none of it (HIG, Menus): only Bold, Italic and
    /// Underline, the text-formatting trio, have them.
    var symbol: String? {
        switch self {
        case .editBold: "bold"
        case .editItalic: "italic"
        case .editUnderline: "underline"
        default: nil
        }
    }

    /// The menus' key equivalents, clear of the system's and on keys every keyboard layout has
    /// (HIG, Keyboards). ⌥⌘G is Go to Page, as in the Mac's PDF readers; Find in PDF… has none, as
    /// ⌘F finds in the PDF while it has the keyboard.
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
        // Pages' Insert › Equation.
        case .editMath: KeyboardShortcut("e", modifiers: [.command, .option])
        case .editComment: KeyboardShortcut("/")
        case .editMoveLineUp: KeyboardShortcut(.upArrow, modifiers: [.command, .control])
        case .editMoveLineDown: KeyboardShortcut(.downArrow, modifiers: [.command, .control])
        case .editGotoLine: KeyboardShortcut("l")
        case .pdfGotoPage: KeyboardShortcut("g", modifiers: [.command, .option])
        case .viewToggleSidebar: KeyboardShortcut("s", modifiers: [.command, .control])
        case .viewTogglePdf: KeyboardShortcut("p", modifiers: [.command, .option])
        case .viewToggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        case .viewToggleLogs: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .viewZoomIn: KeyboardShortcut("=")
        case .viewZoomOut: KeyboardShortcut("-")
        case .viewActualSize: KeyboardShortcut("0")
        case .viewFitWidth: KeyboardShortcut("9")
        case .viewFitPage: KeyboardShortcut("9", modifiers: [.command, .option])
        case .viewTextBigger: KeyboardShortcut("=", modifiers: [.command, .option])
        case .viewTextSmaller: KeyboardShortcut("-", modifiers: [.command, .option])
        case .compileRun: KeyboardShortcut(.return)
        case .compileStop: KeyboardShortcut(".")
        // Xcode's Product › Clean Build Folder.
        case .compileClean: KeyboardShortcut("k", modifiers: [.command, .shift])
        // As the Mac's VS Code LaTeX extension; a double-click goes either way.
        case .syncForward: KeyboardShortcut("j", modifiers: [.command, .option])
        // Xcode's Navigate › Jump to Next Issue.
        case .issueNext: KeyboardShortcut("'")
        case .issuePrevious: KeyboardShortcut("\"")
        case .pdfSave, .projectExport, .fileUpload, .pdfFind, .viewToggleWordCount, .syncInverse: nil
        }
    }
}

enum Prompt: Identifiable, Hashable {
    case gotoLine, gotoPage

    var id: Self { self }
}

/// File › New File or New Folder, for the sidebar to make and name in place: in `folder`,
/// or the folder chosen there.
struct NewEntry: Equatable {
    var directory: Bool
    var folder: String?
}

enum PDFAction {
    case zoomIn, zoomOut, actualSize, fitWidth, fitPage, goToPage(Int), find, inverseFromView
    /// Go to PDF Position's result.
    case reveal(ForwardLoc, SyncTeXWord?)
}

extension AppModel {
    /// `project` is nil on the projects screen or while Settings is in front.
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        switch command {
        case .projectNew, .projectOpen: libraryProblem == nil
        // On Home, the search of the projects.
        case .projectSearch: project != nil || (self.project == nil && mainWindowIsKey)
        case .fileSave, .editBold, .editItalic, .editUnderline, .editMath, .editComment, .editMoveLineUp, .editMoveLineDown, .editGotoLine,
             .viewTextBigger, .viewTextSmaller:
            project?.editsText == true
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .compileStop: project?.compiling == true
        case .viewZoomIn: project.map { $0.hasPDF && $0.pdf.canZoomIn } ?? false
        case .viewZoomOut: project.map { $0.hasPDF && $0.pdf.canZoomOut } ?? false
        case .syncInverse: project.map { $0.hasPDF } ?? false
        case .pdfSave, .filePrint, .pdfFind, .pdfGotoPage, .viewActualSize, .viewFitWidth, .viewFitPage:
            project?.hasPDF == true
        case .syncForward: project.map { $0.hasPDF && $0.isLaTeX } ?? false
        case .issueNext, .issuePrevious: project?.issues.contains { $0.file != nil } == true
        default: project != nil
        }
    }

    /// View-menu titles say what the item will do (HIG, The menu bar).
    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        if command == .projectSearch, self.project == nil { return "Find Project…" }
        let shown: Bool? = switch command {
        case .viewToggleSidebar: sidebarShown
        case .viewTogglePdf: showPDF
        case .viewToggleInspector: inspectorShown
        case .viewToggleLogs: project?.showLogs == true
        case .viewToggleWordCount: showWordCount
        default: nil
        }
        return shown.map { "\($0 ? "Hide" : "Show") \(command.title)" } ?? command.title
    }

    /// With no project there's no file to make, so ⌘N makes a project.
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
        case .fileSave: Task { await project?.saveEdits() }
        case .pdfSave:
            if let project, let url = project.pdfURL {
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
        case .viewToggleLogs: project?.showLogs.toggle()
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
}

extension AppModel {
    /// Live Preview runs TeXpresso, which the core found or was told where to look for.
    var canPreviewLive: Bool { tex?.texpresso != nil }
}

struct AppCommands: Commands {
    let app: AppModel
    /// Nil on the projects screen, and while Settings or a sheet is key, which
    /// turns the project items off.
    private var project: ProjectModel? { app.commandProject }

    private func item(_ command: MenuCommand) -> some View {
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

    private func items(_ commands: [MenuCommand]) -> some View {
        ForEach(commands, id: \.self) { item($0) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item(.projectNew)
            item(.projectOpen)
            Menu("Open Recent") {
                ForEach(app.recents) { recent in
                    Button {
                        Task { await app.open(recent.id) }
                    } label: {
                        Label(recent.name, systemImage: "text.document")
                    }
                    // Documents keep their icon (HIG, Menus); macOS 27 hides menu images otherwise.
                    .labelStyle(.titleAndIcon)
                }
                Divider()
                Button("Clear Menu") { app.recentProjects = [] }
                    .disabled(app.recents.isEmpty)
            }
            Divider()
            items([.fileNew, .fileNewFolder, .fileUpload])
        }
        // After the system's Close (⌘W).
        CommandGroup(after: .saveItem) {
            item(.fileSave)
            Divider()
            item(.projectClose)
            Divider()
            // These act on the chosen item of the list with the keyboard.
            ItemMenuItems(actions: app.mainWindowIsKey ? app.chosenItem : nil, trashShortcut: KeyboardShortcut(.delete))
                .labelStyle(.titleAndIcon)
        }
        CommandGroup(replacing: .importExport) {
            items([.pdfSave, .projectExport])
            Divider()
            if let project, project.hasPDF, let url = project.pdfURL {
                ShareLink(item: url)
            } else {
                Button {} label: { Label("Share…", systemImage: "square.and.arrow.up") }.labelStyle(.titleAndIcon).disabled(true)
            }
        }
        CommandGroup(replacing: .printItem) {
            item(.filePrint)
        }
        // The system's own, answered by whatever has the keyboard; a
        // replacement group loses the spelling and substitution checkmarks.
        TextEditingCommands()
        CommandGroup(before: .textEditing) {
            items([.projectSearch, .pdfFind])
        }
        CommandGroup(replacing: .textFormatting) {
            items([.editBold, .editItalic, .editUnderline])
            Divider()
            Menu("Section Level") { SectionLevelItems(project: project) }
                .disabled(project?.isLaTeX != true)
            Divider()
            items([.editComment, .editMoveLineUp, .editMoveLineDown])
        }
        CommandGroup(replacing: .sidebar) {
            item(.viewToggleSidebar)
            // The keyboard's and VoiceOver's way to the File Outline header's fold.
            Button(app.outlineCollapsed ? "Show File Outline" : "Hide File Outline") { app.outlineCollapsed.toggle() }
                .disabled(project?.isLaTeX != true || !app.sidebarShown)
            items([.viewTogglePdf, .viewToggleInspector, .viewToggleLogs, .viewToggleWordCount])
            Divider()
            items([.viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitPage])
            Divider()
            // The source's, as Settings sets it; the zoom above is the PDF's.
            items([.viewTextBigger, .viewTextSmaller])
        }
        // The app's own menus go between View and Window (HIG, The menu bar).
        CommandMenu("Go") {
            items([.editGotoLine, .pdfGotoPage])
            Divider()
            items([.syncForward, .syncInverse])
            Divider()
            items([.issueNext, .issuePrevious])
        }
        CommandMenu("Insert") {
            Group {
                MathMenuItems(project: project, shortcut: app.shortcut(.editMath, on: project)) {
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
            // A mode, like the one above: checked while its window is live. Disk changes rescan on their own.
            Toggle("Live Preview", isOn: Binding(
                get: { project?.texpresso.active == true },
                set: { $0 ? project?.startTeXpresso() : project?.stopTeXpresso() }))
                .disabled(!app.canPreviewLive || project.map { !$0.initialLoadComplete || $0.texpresso.phase == .stopping } ?? true)
            Divider()
            EnginePicker(project: project)
            // The open file; the files' context menu has it for any .tex file.
            Button("Set as Main File") {
                if let project, let path = project.openPath { Task { await project.setMainFile(path) } }
            }
            .disabled(project?.isLaTeX != true || project?.openPath == project?.settings?.mainFile)
        }
    }
}
