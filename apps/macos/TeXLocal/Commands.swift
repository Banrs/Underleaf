import SwiftUI
import UniformTypeIdentifiers

enum MenuCommand: CaseIterable {
    case projectNew, projectOpen, projectClose, projectExport, projectSearch
    case fileNew, fileNewFolder, fileUpload, fileSave, pdfSave, filePrint
    case editBold, editItalic, editUnderline, editMath, editComment, editShiftRight, editShiftLeft, editMoveLineUp, editMoveLineDown
    case editGotoLine, jumpToDefinition, editRename
    case pdfFind, pdfGotoPage
    case viewToggleSidebar, viewTogglePDF, viewToggleInspector, viewToggleLogs, viewToggleWordCount
    case viewZoomIn, viewZoomOut, viewActualSize, viewFitWidth, viewFitPage
    case compileRun, compileStop, compileClean, syncForward, syncInverse, issueNext, issuePrevious

    var title: String { spec.title }
    var shortcut: KeyboardShortcut? { spec.shortcut }

    /// Each command's title and key, side by side. ⌥⌘G is Go to Page, as in the Mac's PDF readers; Find in PDF… has none,
    /// as ⌘F finds in the PDF while it has the keyboard.
    private var spec: (title: String, shortcut: KeyboardShortcut?) {
        switch self {
        case .projectNew: ("New Project…", KeyboardShortcut("n", modifiers: [.command, .shift]))
        case .projectOpen: ("Open…", KeyboardShortcut("o"))
        case .projectClose: ("Close Project", KeyboardShortcut("w", modifiers: [.command, .shift]))
        case .projectExport: ("Export Project as ZIP…", nil)
        case .projectSearch: ("Find in Project…", KeyboardShortcut("f", modifiers: [.command, .shift]))
        case .fileNew: ("New File", KeyboardShortcut("n"))
        case .fileNewFolder: ("New Folder", KeyboardShortcut("n", modifiers: [.command, .shift, .option]))
        case .fileUpload: ("Add Files…", nil)
        case .fileSave: ("Save", KeyboardShortcut("s"))
        case .pdfSave: ("Export as PDF…", nil)
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
        case .editGotoLine: ("Go to Line…", KeyboardShortcut("l"))
        case .jumpToDefinition: ("Jump to Definition", KeyboardShortcut("j", modifiers: [.command, .control]))
        case .editRename: ("Rename…", nil)
        case .pdfFind: ("Find in PDF…", nil)
        case .pdfGotoPage: ("Go to Page…", KeyboardShortcut("g", modifiers: [.command, .option]))
        case .viewToggleSidebar: ("Sidebar", KeyboardShortcut("s", modifiers: [.command, .control]))
        case .viewTogglePDF: ("PDF", KeyboardShortcut("p", modifiers: [.command, .option]))
        case .viewToggleInspector: ("Inspector", KeyboardShortcut("i", modifiers: [.command, .option]))
        case .viewToggleLogs: ("Build Panel", KeyboardShortcut("y", modifiers: [.command, .shift]))
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

    /// Text commands on the source's selection, which the menu bar's follow the source's keyboard for (`isEnabledInMenuBar`).
    var editsSelection: Bool {
        switch self {
        case .editBold, .editItalic, .editUnderline, .editMath, .editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp,
             .editMoveLineDown, .jumpToDefinition, .editRename: true
        default: false
        }
    }

    /// The format toggles' symbol, and what they do (HIG, Offering help).
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
    case gotoLine, gotoPage, rename(Definition)

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
        case .fileSave, .editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp, .editMoveLineDown, .editGotoLine, .jumpToDefinition:
            project?.editsText == true
        case .editBold, .editItalic, .editUnderline, .editMath: project?.isLaTeX == true
        case .editRename: project.map { $0.editsText && $0.editor.renamable != nil } ?? false
        case .compileRun: tex?.available == true && project?.compiling == false
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

    /// As Xcode's and Notes': with a field, the file list or the PDF focused, the menu bar's text commands are dim and their
    /// shortcuts are the focused view's. The toolbar's still act on the source, which is theirs.
    func isEnabledInMenuBar(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        isEnabled(command, on: project) && (!command.editsSelection || project?.sourceHasKeyboard == true)
    }

    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        let shown: Bool? = switch command {
        case .viewToggleSidebar: sidebarShown
        case .viewTogglePDF: showPDF
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
        case .projectExport: if let project { exporting = ExportFile(name: "\(project.name).zip", type: .zip, make: project.exportZip) }
        case .projectSearch:
            sidebarShown = true
            searchFocusToken += 1
        case .fileNew, .fileNewFolder:
            sidebarShown = true
            newEntry = NewEntry(directory: command == .fileNewFolder)
        case .fileUpload: addingFiles = true
        case .fileSave: Task { await project?.save() }
        case .pdfSave: if let project, let url = project.buildPDF { exporting = ExportFile(name: "\(project.name).pdf", type: .pdf) { url } }
        // The PDF, not the first responder (usually the source), and whether or not its pane shows.
        case .filePrint: if let project { project.pdf.print(title: project.name, file: project.livePDF ? project.buildPDF : nil) }
        case .editBold: project?.editor.perform(.bold)
        case .editItalic: project?.editor.perform(.italic)
        case .editUnderline: project?.editor.perform(.underline)
        case .editMath: project?.editor.perform(.math)
        case .editComment: project?.editor.perform(.comment)
        case .editShiftRight: project?.editor.textView.shiftLines(1)
        case .editShiftLeft: project?.editor.textView.shiftLines(-1)
        case .editMoveLineUp: project?.editor.perform(.moveLineUp)
        case .editMoveLineDown: project?.editor.perform(.moveLineDown)
        case .editGotoLine: prompt = .gotoLine
        case .jumpToDefinition: project?.editor.jumpToDefinition()
        case .editRename: prompt = project?.editor.renamable.map(Prompt.rename)
        case .pdfGotoPage: prompt = .gotoPage
        case .pdfFind: requestPDF(.find)
        case .viewToggleSidebar: sidebarShown.toggle()
        case .viewTogglePDF: togglePDF()
        case .viewToggleInspector: inspectorShown.toggle()
        case .viewToggleLogs: project?.panel.shown.toggle()
        case .viewToggleWordCount: showWordCount.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewActualSize: requestPDF(.actualSize)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitPage: requestPDF(.fitPage)
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

    private func items(_ commands: MenuCommand...) -> some View {
        ForEach(commands, id: \.self) { CommandItem(app: app, command: $0) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items(.projectNew, .fileNew, .fileNewFolder, .projectOpen)
            Menu("Open Recent") {
                ForEach(app.recents) { recent in
                    Button(recent.name, systemImage: "text.document") { Task { await app.open(recent.id) } }
                    // macOS 27 hides a menu item's image unless the label style shows it.
                    .labelStyle(.titleAndIcon)
                }
                Divider()
                Button("Clear Menu") { app.recentProjects = [] }
                    .disabled(app.recents.isEmpty)
            }
            Divider()
            items(.fileUpload)
        }
        CommandGroup(after: .saveItem) {
            items(.fileSave)
            Divider()
            items(.projectClose)
            Divider()
            ItemMenuItems(actions: app.mainWindowIsKey ? app.chosenItem : nil, trashShortcut: KeyboardShortcut(.delete))
                .labelStyle(.titleAndIcon)
        }
        CommandGroup(replacing: .importExport) {
            items(.pdfSave, .projectExport)
            Divider()
            if let project, let url = project.buildPDF {
                ShareLink(item: url)
            } else {
                Button("Share…", systemImage: "square.and.arrow.up") {}.labelStyle(.titleAndIcon).disabled(true)
            }
        }
        CommandGroup(replacing: .printItem) { items(.filePrint) }
        // A replacement group would lose the spelling and substitution checkmarks.
        TextEditingCommands()
        CommandGroup(before: .textEditing) { items(.projectSearch, .pdfFind) }
        CommandGroup(after: .pasteboard) {
            Divider()
            items(.editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp, .editMoveLineDown)
            Divider()
            items(.editRename)
        }
        // A submenu stays available while its items are dim (HIG Menus).
        CommandGroup(replacing: .textFormatting) {
            Menu("Font") { items(.editBold, .editItalic, .editUnderline) }
            Menu("Section Level") { SectionLevelItems(project: project) }
        }
        CommandGroup(replacing: .sidebar) {
            items(.viewToggleSidebar)
            Button(app.outlineOpen(of: project) ? "Hide File Outline" : "Show File Outline") { app.outlineCollapsed.toggle() }
                .disabled(project?.isLaTeX != true || project?.search.isSearching == true || !app.sidebarShown)
            items(.viewTogglePDF, .viewToggleInspector, .viewToggleLogs, .viewToggleWordCount)
            Divider()
            items(.viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitPage)
        }
        CommandMenu("Go") {
            items(.editGotoLine, .pdfGotoPage)
            Divider()
            items(.jumpToDefinition)
            Divider()
            items(.syncForward, .syncInverse)
            Divider()
            items(.issueNext, .issuePrevious)
        }
        CommandMenu("Insert") {
            MathMenuItems(project: project, shortcut: MenuCommand.editMath.shortcut,
                          inlineMathEnabled: app.isEnabledInMenuBar(.editMath, on: project)) { app.perform(.editMath, on: project) }
            Divider()
            InsertMenuItems(project: project)
        }
        CommandMenu("Compile") {
            items(.compileRun, .compileStop, .compileClean)
            Divider()
            Toggle("Compile Automatically", isOn: Bindable(app).autoCompile)
            LivePreviewItem(app: app)
            Divider()
            Menu("Engine") { EnginePicker(project: project).pickerStyle(.inline).labelsHidden() }
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
            if let symbol = command.style?.symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .labelStyle(.titleAndIcon)
        // ⌘N follows whether a project is open, not which window is key.
        .keyboardShortcut(app.shortcut(command, on: app.project))
        .disabled(!app.isEnabledInMenuBar(command, on: project))
    }
}

/// The inspector's and Compile ▸ Engine's, whose choices dim with no project rather than the submenu. A project's engine,
/// even nil or unlisted, is a choice: a selection with no tag is a SwiftUI fault.
struct EnginePicker: View {
    let project: ProjectModel?

    var body: some View {
        let engine = project?.settings?.engine
        Picker("Engine", selection: Binding(get: { engine }, set: { new in
            if let project, let new { Task.immediate { await project.patchSettings(.engine(new)) } }
        })) {
            ForEach(TeXEngine.allCases) { Text($0.title).tag(Optional($0.id)) }
            if project != nil, engine.flatMap(TeXEngine.init) == nil { Text(engine ?? "").tag(engine) }
        }
        .disabled(engine == nil)
    }
}

private struct LivePreviewItem: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        Toggle("Live Preview", isOn: project.map { Bindable($0).livePreview } ?? .constant(false))
            .disabled(project?.canSwitchLivePreview != true)
    }
}

private struct SetMainFileItem: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        Button("Set as Main File") {
            if let project, let path = project.openPath { Task { await project.patchSettings(.mainFile(path)) } }
        }
        .disabled(project?.isLaTeX != true || project?.openPath == project?.settings?.mainFile)
    }
}
