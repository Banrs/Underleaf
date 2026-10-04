import AppKit
import SwiftUI

/// The app's commands and their key equivalents.
enum MenuCommand: String, CaseIterable {
    case projectNew = "project.new"
    case projectOpen = "project.open"
    case projectClose = "project.close"
    case projectExport = "project.export"
    case projectSearch = "project.search"
    case fileNew = "file.new"
    case fileNewFolder = "file.newFolder"
    case fileUpload = "file.upload"
    case fileSave = "file.save"
    case pdfSave = "pdf.save"
    case filePageSetup = "file.pageSetup"
    case filePrint = "file.print"
    case editBold = "edit.bold"
    case editItalic = "edit.italic"
    case editUnderline = "edit.underline"
    case editMath = "edit.math"
    case editComment = "edit.comment"
    case editMoveLineUp = "edit.moveLineUp"
    case editMoveLineDown = "edit.moveLineDown"
    case editGotoLine = "edit.gotoLine"
    case pdfFind = "pdf.find"
    case pdfGotoPage = "pdf.gotoPage"
    case viewToggleSidebar = "view.toggleSidebar"
    case viewTogglePdf = "view.togglePdf"
    case viewToggleInspector = "view.toggleInspector"
    case viewToggleLogs = "view.toggleLogs"
    case viewToggleWordCount = "view.toggleWordCount"
    case viewZoomIn = "view.zoomIn"
    case viewZoomOut = "view.zoomOut"
    case viewActualSize = "view.actualSize"
    case viewFitWidth = "view.fitWidth"
    case viewFitPage = "view.fitPage"
    case compileRun = "compile.run"
    case compileStop = "compile.stop"
    case syncForward = "sync.forward"
    case syncInverse = "sync.inverse"

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
        case .pdfSave: "Save PDF As…"
        case .filePageSetup: "Page Setup…"
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
        case .compileRun: "Compile"
        case .compileStop: "Stop"
        case .syncForward: "Go to PDF Position"
        case .syncInverse: "Go to Source Position"
        }
    }

    /// The standard icon for the action (HIG, Icons) where its group has them: the system's Close
    /// above Save has one, and Bold, Italic and Underline are the HIG's text-formatting trio.
    var symbol: String? {
        switch self {
        case .fileSave: "square.and.arrow.down"
        case .editBold: "bold"
        case .editItalic: "italic"
        case .editUnderline: "underline"
        case .projectSearch, .pdfFind: "text.page.badge.magnifyingglass"
        default: nil
        }
    }

    /// The menus' key equivalents, clear of the system's (HIG, Keyboards). ⌥⌘G is Go to
    /// Page, as in the Mac's PDF readers; Find in PDF… has none, as ⌘F finds in the PDF
    /// while it has the keyboard.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .projectNew: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .projectOpen: KeyboardShortcut("o")
        case .projectClose: KeyboardShortcut("w", modifiers: [.command, .shift])
        case .projectSearch: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .fileNew: KeyboardShortcut("n")
        case .fileNewFolder: KeyboardShortcut("n", modifiers: [.command, .shift, .option])
        case .fileSave: KeyboardShortcut("s")
        case .pdfSave: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .filePageSetup: KeyboardShortcut("p", modifiers: [.command, .shift])
        case .filePrint: KeyboardShortcut("p")
        case .editBold: KeyboardShortcut("b")
        case .editItalic: KeyboardShortcut("i")
        case .editUnderline: KeyboardShortcut("u")
        // Pages' Insert › Equation.
        case .editMath: KeyboardShortcut("e", modifiers: [.command, .option])
        case .editComment: KeyboardShortcut("/")
        // Xcode's Editor › Structure.
        case .editMoveLineUp: KeyboardShortcut("[", modifiers: [.command, .option])
        case .editMoveLineDown: KeyboardShortcut("]", modifiers: [.command, .option])
        case .editGotoLine: KeyboardShortcut("l")
        case .pdfGotoPage: KeyboardShortcut("g", modifiers: [.command, .option])
        case .viewToggleSidebar: KeyboardShortcut("s", modifiers: [.command, .control])
        case .viewTogglePdf: KeyboardShortcut("\\", modifiers: [.command, .shift])
        case .viewToggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        case .viewToggleLogs: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .viewZoomIn: KeyboardShortcut("=")
        case .viewZoomOut: KeyboardShortcut("-")
        case .viewActualSize: KeyboardShortcut("0")
        case .viewFitWidth: KeyboardShortcut("9")
        case .viewFitPage: KeyboardShortcut("9", modifiers: [.command, .option])
        case .compileRun: KeyboardShortcut(.return)
        case .compileStop: KeyboardShortcut(".")
        // As the Mac's VS Code LaTeX extension; the PDF answers a double-click for the other way.
        case .syncForward: KeyboardShortcut("j", modifiers: [.command, .option])
        case .projectExport, .fileUpload, .pdfFind, .viewToggleWordCount, .syncInverse: nil
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
    case zoomIn, zoomOut, actualSize, fitWidth, fitPage, goToPage(Int), find, inverseFromView, print
    /// Go to PDF Position's result.
    case reveal(ForwardLoc, SyncTeXWord?)
}

extension AppModel {
    /// `project` is nil on the projects screen or while Settings is in front.
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        switch command {
        case .projectNew, .projectOpen, .filePageSetup: true
        case .fileSave, .editBold, .editItalic, .editUnderline, .editMath, .editComment, .editMoveLineUp, .editMoveLineDown, .editGotoLine:
            project?.editsText == true
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .compileStop: project?.compiling == true
        case .viewZoomIn: project.map { $0.hasPDF && $0.pdf.canZoomIn } ?? false
        case .viewZoomOut: project.map { $0.hasPDF && $0.pdf.canZoomOut } ?? false
        case .pdfSave, .filePrint, .pdfFind, .pdfGotoPage, .viewActualSize, .viewFitWidth, .viewFitPage, .syncInverse:
            project?.hasPDF == true
        case .syncForward: project.map { $0.hasPDF && $0.isLaTeX } ?? false
        default: project != nil
        }
    }

    /// View-menu titles say what the item will do (HIG, The menu bar).
    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        let shown: Bool? = switch command {
        case .viewToggleSidebar: sidebarVisible
        case .viewTogglePdf: showPDF
        case .viewToggleInspector: inspectorVisible
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
            sidebarVisible = true
            searchFocusToken += 1
        case .fileNew, .fileNewFolder:
            sidebarVisible = true
            newEntry = NewEntry(directory: command == .fileNewFolder)
        case .fileUpload: addingFiles = true
        case .fileSave: Task { await project?.saveEdits() }
        case .pdfSave:
            if let project, let url = project.pdfURL {
                exporting = ExportFile(name: "\(project.id).pdf", type: .pdf) { url }
            }
        // AppKit: SwiftUI has no page setup panel.
        case .filePageSetup: NSApp.runPageLayout(nil)
        // The PDF, not the first responder (usually the source).
        case .filePrint: requestPDF(.print)
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
        case .viewToggleSidebar: sidebarVisible.toggle()
        case .viewTogglePdf: togglePDF()
        case .viewToggleInspector: inspectorVisible.toggle()
        case .viewToggleLogs: project?.showLogs.toggle()
        case .viewToggleWordCount: showWordCount.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewActualSize: requestPDF(.actualSize)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitPage: requestPDF(.fitPage)
        case .compileRun: Task { await project?.compile() }
        case .compileStop: project?.stopCompile()
        case .syncForward: Task { await project?.forwardSync() }
        case .syncInverse: requestPDF(.inverseFromView)
        }
    }
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
                    // An object rather than an action, so it keeps its icon
                    // (HIG, Menus); macOS 27 hides menu images otherwise.
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
            // These act on the chosen item of the list with the keyboard. After Save, as
            // Pages and Finder put Rename; the standard icons (HIG, Icons) on all three.
            let chosen = app.mainWindowIsKey ? app.chosenItem : nil
            Button { chosen?.rename() } label: { Label("Rename", systemImage: "pencil") }.labelStyle(.titleAndIcon)
                .disabled(chosen == nil)
            Button { chosen?.showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }.labelStyle(.titleAndIcon)
                .disabled(chosen == nil)
            Button { chosen?.moveToTrash() } label: { Label("Move to Trash", systemImage: "trash") }.labelStyle(.titleAndIcon)
                .keyboardShortcut(.delete)
                .disabled(chosen == nil)
            Divider()
            items([.pdfSave, .projectExport])
            Divider()
            if let project, project.hasPDF, let url = project.pdfURL {
                ShareLink(item: url)
            } else {
                Button {} label: { Label("Share…", systemImage: "square.and.arrow.up") }.labelStyle(.titleAndIcon).disabled(true)
            }
        }
        CommandGroup(replacing: .printItem) {
            item(.filePageSetup)
            item(.filePrint)
        }
        // The system's own, answered by whatever has the keyboard; a
        // replacement group loses the spelling and substitution checkmarks.
        TextEditingCommands()
        CommandGroup(before: .textEditing) {
            item(.editGotoLine)
            item(.pdfGotoPage)
            Divider()
            item(.projectSearch)
            item(.pdfFind)
        }
        CommandGroup(replacing: .textFormatting) {
            items([.editBold, .editItalic, .editUnderline])
            Divider()
            Menu("Section Level") { SectionLevelItems(project: project) }
                .disabled(project?.isLaTeX != true)
            Divider()
            // As Xcode's Editor › Structure has them.
            items([.editComment, .editMoveLineUp, .editMoveLineDown])
        }
        CommandGroup(before: .toolbar) {
            item(.viewToggleSidebar)
            // The keyboard's and VoiceOver's way to the File Outline header's fold.
            Button(app.outlineCollapsed ? "Show File Outline" : "Hide File Outline") { app.outlineCollapsed.toggle() }
                .disabled(project?.isLaTeX != true || !app.sidebarVisible)
            items([.viewTogglePdf, .viewToggleInspector, .viewToggleLogs, .viewToggleWordCount])
            Divider()
            items([.viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitPage])
            Divider()
        }
        // The app's own menus go between View and Window (HIG, The menu bar).
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
            items([.compileRun, .compileStop])
            Toggle("Compile Automatically", isOn: Bindable(app).autoCompile)
            // Only with a project's settings, and their engine always a choice: a
            // selection no tag matches, nil included, is a SwiftUI fault.
            if let project, let engine = project.settings?.engine {
                Picker("Engine", selection: Binding(get: { engine }, set: { new in Task { await project.setEngine(new) } })) {
                    ForEach(texEngines, id: \.0) { id, title in Text(title).tag(id) }
                    if !texEngines.contains(where: { $0.0 == engine }) { Text(engine).tag(engine) }
                }
            } else {
                Menu("Engine") { ForEach(texEngines, id: \.0) { Text($0.1) } }
            }
            // The open file; the files' context menu has it for any .tex file.
            Button("Set as Main File") {
                if let project, let path = project.openPath { Task { await project.setMainFile(path) } }
            }
            .disabled(project?.isLaTeX != true || project?.openPath == project?.settings?.mainFile)
            Divider()
            items([.syncForward, .syncInverse])
        }
    }
}
