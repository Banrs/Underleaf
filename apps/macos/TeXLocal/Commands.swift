import AppKit
import SwiftUI

/// The app's commands, with the web's ids (web/src/workspace.js `commandDefs`)
/// and its accelerators, which drive the menu's key equivalents.
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
    case editUndo = "edit.undo"
    case editRedo = "edit.redo"
    case editFind = "edit.find"
    case editFindAndReplace = "edit.findAndReplace"
    case editFindNext = "edit.findNext"
    case editFindPrevious = "edit.findPrevious"
    case editBold = "edit.bold"
    case editItalic = "edit.italic"
    case editMath = "edit.math"
    case editComment = "edit.comment"
    case editGotoLine = "edit.gotoLine"
    case pdfFind = "pdf.find"
    /// Mac only: the web's viewer has no page field to go to.
    case pdfGotoPage = "pdf.gotoPage"
    case viewToggleSidebar = "view.toggleSidebar"
    case viewTogglePdf = "view.togglePdf"
    /// The web's id, which predates the name.
    case viewToggleInspector = "view.toggleInspector"
    case viewToggleLogs = "view.toggleLogs"
    case viewToggleWordCount = "view.toggleWordCount"
    case viewZoomIn = "view.zoomIn"
    case viewZoomOut = "view.zoomOut"
    case viewActualSize = "view.actualSize"
    case viewFitWidth = "view.fitWidth"
    case viewFitHeight = "view.fitHeight"
    case compileRun = "compile.run"
    case compileStop = "compile.stop"
    case compileToggleAuto = "compile.toggleAuto"
    case syncForward = "sync.forward"
    case syncInverse = "sync.inverse"

    var title: String {
        switch self {
        case .projectNew: "New Project…"
        case .projectOpen: "Open…"
        case .projectClose: "Close Project"
        case .projectExport: "Export Project as ZIP…"
        case .projectSearch: "Find in Project…"
        case .fileNew: "New File…"
        case .fileNewFolder: "New Folder…"
        case .fileUpload: "Add Files…"
        case .fileSave: "Save"
        case .pdfSave: "Save PDF As…"
        case .filePageSetup: "Page Setup…"
        case .filePrint: "Print…"
        case .editUndo: "Undo"
        case .editRedo: "Redo"
        case .editFind: "Find…"
        case .editFindAndReplace: "Find and Replace…"
        case .editFindNext: "Find Next"
        case .editFindPrevious: "Find Previous"
        case .editBold: "Bold"
        case .editItalic: "Italic"
        case .editMath: "Inline Math"
        case .editComment: "Comment Selection"
        case .editGotoLine: "Go to Line…"
        case .pdfFind: "Find in PDF…"
        case .pdfGotoPage: "Go to Page…"
        case .viewToggleSidebar: "Hide Sidebar"
        case .viewTogglePdf: "Hide PDF"
        case .viewToggleInspector: "Hide Inspector"
        case .viewToggleLogs: "Build Panel"
        case .viewToggleWordCount: "Hide Word Count"
        case .viewZoomIn: "Zoom In"
        case .viewZoomOut: "Zoom Out"
        case .viewActualSize: "Actual Size"
        case .viewFitWidth: "Fit Width"
        case .viewFitHeight: "Fit Height"
        case .compileRun: "Compile"
        case .compileStop: "Stop"
        case .compileToggleAuto: "Compile Automatically"
        case .syncForward: "Go to PDF Position"
        case .syncInverse: "Go to Source Position"
        }
    }

    /// The shared accelerator (web/src/shortcuts.json, which the build copies into the app).
    var accel: String? { Self.sharedAccels[rawValue] }

    private static let sharedAccels: [String: String] = {
        guard let url = Bundle.main.url(forResource: "shortcuts", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    /// Departs from the shared table where the HIG reserves its key (HIG, Keyboards); Sync
    /// and Inline Math leave the table's Control and ⇧⌘M (Minimize plus Shift) chords.
    var macAccel: String? {
        switch self {
        case .projectOpen: "CmdOrCtrl+O"
        case .filePageSetup: "CmdOrCtrl+Shift+P"
        case .filePrint: "CmdOrCtrl+P"
        case .editFindAndReplace: "CmdOrCtrl+Alt+F"
        case .viewToggleSidebar: "Ctrl+CmdOrCtrl+S"
        case .viewToggleInspector: "CmdOrCtrl+Alt+I"
        case .viewActualSize: "CmdOrCtrl+0"
        case .viewFitWidth: "CmdOrCtrl+9"
        case .viewFitHeight: "CmdOrCtrl+Alt+9"
        case .compileStop: "CmdOrCtrl+."
        case .projectClose: "CmdOrCtrl+Shift+W"
        // Pages' Insert › Equation.
        case .editMath: "CmdOrCtrl+Alt+E"
        // As the Mac's VS Code LaTeX extension; the PDF answers ⌘-click for the other way.
        case .syncForward: "CmdOrCtrl+Alt+J"
        case .syncInverse: nil
        // ⌥⌘G is Go to Page in the Mac's PDF readers; ⌘L is Go to Line.
        case .pdfGotoPage: "CmdOrCtrl+Alt+G"
        // ⌘F finds in the PDF when it has the keyboard.
        case .pdfFind: nil
        default: accel
        }
    }

    var shortcut: KeyboardShortcut? {
        macAccel.flatMap(Self.shortcut(for:))
    }

    /// "CmdOrCtrl+Shift+Z" → ⇧⌘Z.
    static func shortcut(for accel: String) -> KeyboardShortcut? {
        var parts = accel.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast() else { return nil }
        var modifiers: EventModifiers = []
        for part in parts {
            switch part {
            case "CmdOrCtrl": modifiers.insert(.command)
            case "Ctrl": modifiers.insert(.control)
            case "Alt": modifiers.insert(.option)
            case "Shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let equivalent: KeyEquivalent
        switch key {
        case "Return": equivalent = .return
        case "Plus": equivalent = "="
        case "Minus": equivalent = "-"
        default:
            guard key.count == 1, let c = key.lowercased().first else { return nil }
            equivalent = KeyEquivalent(c)
        }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

/// A sheet the workspace asks for a value with.
enum Prompt: Identifiable, Hashable {
    /// In the folder given, or the open file's.
    case newFile(in: String? = nil), newFolder(in: String? = nil), gotoLine, gotoPage

    var id: Self { self }
}

/// What the menus ask of the PDF pane (`AppModel.requestPDF`).
enum PDFAction {
    case zoomIn, zoomOut, actualSize, fitWidth, fitHeight, goToPage(Int), find, inverseFromView, print
}

extension AppModel {
    /// `project` is nil on the projects screen or while Settings is in front.
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        switch command {
        case .projectNew, .projectOpen, .filePageSetup: true
        case .fileSave, .editBold, .editItalic, .editMath, .editComment, .editGotoLine:
            project?.editsText == true
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .compileStop: project?.compiling == true
        case .viewZoomIn: project.map { $0.hasPDF && $0.pdfCanZoomIn } ?? false
        case .viewZoomOut: project.map { $0.hasPDF && $0.pdfCanZoomOut } ?? false
        case .pdfSave, .filePrint, .pdfFind, .pdfGotoPage, .viewActualSize, .viewFitWidth, .viewFitHeight, .syncInverse:
            project?.hasPDF == true
        case .syncForward: project.map { $0.hasPDF && $0.editsText } ?? false
        default: project != nil
        }
    }

    /// View-menu titles say what the item will do (HIG, The menu bar).
    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        switch command {
        case .viewToggleSidebar: sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        case .viewTogglePdf: project?.showPDF == false ? "Show PDF" : "Hide PDF"
        case .viewToggleInspector: inspectorVisible ? "Hide Inspector" : "Show Inspector"
        case .viewToggleLogs: project?.showLogs == true ? "Hide Build Panel" : "Show Build Panel"
        case .viewToggleWordCount: showWordCount ? "Hide Word Count" : "Show Word Count"
        default: command.title
        }
    }

    /// With no project there's no file to make, so ⌘N makes a project (home.js).
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
        case .fileNew: prompt = .newFile()
        case .fileNewFolder: prompt = .newFolder()
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
        case .editBold: project?.format(.bold)
        case .editItalic: project?.format(.italic)
        case .editMath: project?.format(.math)
        case .editComment: project?.format(.comment)
        case .editGotoLine: prompt = .gotoLine
        case .pdfGotoPage: prompt = .gotoPage
        case .pdfFind: requestPDF(.find)
        case .viewToggleSidebar: sidebarVisible.toggle()
        case .viewTogglePdf: project?.showPDF.toggle()
        case .viewToggleInspector: inspectorVisible.toggle()
        case .viewToggleLogs: project?.showLogs.toggle()
        case .viewToggleWordCount: showWordCount.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewActualSize: requestPDF(.actualSize)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitHeight: requestPDF(.fitHeight)
        case .compileRun: Task { await project?.compile() }
        case .compileStop: project?.stopCompile()
        // A Toggle bound to `autoCompile` in the menu. Undo, Redo and the Find items
        // are the system's, which reach whatever has the keyboard (the source's
        // text view, `MainWindowController.performFindPanelAction`).
        case .compileToggleAuto, .editUndo, .editRedo, .editFind, .editFindAndReplace, .editFindNext, .editFindPrevious:
            break
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
        Button(app.title(command, on: project)) { app.perform(command, on: project) }
        // ⌘N follows whether a project is open, not which window is key.
        .keyboardShortcut(app.shortcut(command, on: app.project))
        .disabled(!app.isEnabled(command, on: project))
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
            item(.fileNew)
            item(.fileNewFolder)
            item(.fileUpload)
            Divider()
            // Not MenuCommands: the web has no command ids for them. They act on the
            // chosen item of the list with the keyboard.
            let chosen = app.mainWindowIsKey ? app.chosenItem : nil
            Button("Rename") { chosen?.rename() }
                .disabled(chosen == nil)
            Button("Show in Finder") { chosen?.showInFinder() }
                .disabled(chosen == nil)
            Divider()
            Button("Move to Trash") { chosen?.moveToTrash() }
                .keyboardShortcut(.delete)
                .disabled(chosen == nil)
        }
        // After the system's Close (⌘W).
        CommandGroup(after: .saveItem) {
            item(.fileSave)
            Divider()
            item(.projectClose)
            Divider()
            // Always shown, disabled while there's no PDF.
            item(.pdfSave)
            item(.projectExport)
            Divider()
            // The system's Share… item. Not a MenuCommand: the web has no command id for it.
            if let project, project.hasPDF, let url = project.pdfURL {
                ShareLink(item: url)
            } else {
                Button("Share…") {}.disabled(true)
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
            item(.editBold)
            item(.editItalic)
            Divider()
            Menu("Section Level") { SectionLevelItems(project: project) }
                .disabled(project?.isLaTeX != true)
            Divider()
            item(.editComment)
        }
        // The columns left to right, then the build panel below them.
        CommandGroup(after: .sidebar) {
            item(.viewToggleSidebar)
            // Not a MenuCommand: the web has no command id for it. The keyboard's
            // and VoiceOver's way to the sidebar header's fold.
            Button(app.outlineCollapsed ? "Show File Outline" : "Hide File Outline") { app.outlineCollapsed.toggle() }
                .disabled(project?.isLaTeX != true || !app.sidebarVisible)
            item(.viewTogglePdf)
            item(.viewToggleInspector)
            item(.viewToggleLogs)
            item(.viewToggleWordCount)
            Divider()
            item(.viewZoomIn)
            item(.viewZoomOut)
            item(.viewActualSize)
            item(.viewFitWidth)
            item(.viewFitHeight)
            Divider()
        }
        // The app's own menus go between View and Window (HIG, The menu bar).
        CommandMenu("Insert") {
            InsertMenuItems(project: project, inlineMath: item(.editMath))
                .disabled(project?.isLaTeX != true)
        }
        CommandMenu("Compile") {
            item(.compileRun)
            item(.compileStop)
            Toggle(MenuCommand.compileToggleAuto.title, isOn: Bindable(app).autoCompile)
            // Only with a project's settings, and their engine always a choice: a
            // selection no tag matches, nil included, is a SwiftUI fault.
            if let project, let engine = project.settings?.engine {
                Picker("Engine", selection: Binding(get: { engine }, set: { new in Task { await project.setEngine(new) } })) {
                    ForEach(texEngines, id: \.0) { id, title in Text(title).tag(id) }
                    if !texEngines.contains(where: { $0.0 == engine }) { Text(engine).tag(engine) }
                }
            } else {
                Menu("Engine") {}
                    .disabled(true)
            }
            // The open file; the files' context menu has it for any .tex file.
            Button("Set as Main File") {
                if let project, let path = project.openPath { Task { await project.setMainFile(path) } }
            }
            .disabled(project?.isLaTeX != true || project?.openPath == project?.settings?.mainFile)
            Divider()
            item(.syncForward)
            item(.syncInverse)
        }
    }
}
