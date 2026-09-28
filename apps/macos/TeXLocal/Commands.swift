import AppKit
import os
import SwiftUI

/// The app's commands, with the web's ids (web/src/workspace.js `commandDefs`)
/// and its accelerators. One accelerator string drives both the menu's key
/// equivalent and the chords the editor page hands back.
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
    case viewToggleProjectSettings = "view.toggleInspector"
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
        case .viewToggleProjectSettings: "Hide Project Settings"
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

    /// The shared accelerator (web/src/shortcuts.json, which the build copies
    /// into the app); `macAccel` departs from it where the HIG reserves a key.
    var accel: String? { Self.sharedAccels[rawValue] }

    private static let sharedAccels: [String: String] = {
        guard let url = Bundle.main.url(forResource: "shortcuts", withExtension: "json", subdirectory: "web"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else {
            Logger(subsystem: "com.texlocal.mac", category: "commands").fault("web/shortcuts.json is missing from the app")
            return [:]
        }
        return table
    }()

    /// Mac chords where HIG-reserved keys differ from the shared table (HIG,
    /// Keyboards): ⌃⌘S sidebar, ⌘0 actual size, ⌥⌘F find and replace, ⌘. stop.
    var macAccel: String? {
        switch self {
        case .projectOpen: "CmdOrCtrl+O"
        case .filePageSetup: "CmdOrCtrl+Shift+P"
        case .filePrint: "CmdOrCtrl+P"
        case .editFindAndReplace: "CmdOrCtrl+Alt+F"
        case .viewToggleSidebar: "Ctrl+CmdOrCtrl+S"
        case .viewToggleProjectSettings: "CmdOrCtrl+Alt+I"
        case .viewActualSize: "CmdOrCtrl+0"
        case .viewFitWidth: "CmdOrCtrl+9"
        case .viewFitHeight: "CmdOrCtrl+Alt+9"
        case .compileStop: "CmdOrCtrl+."
        // Preview's.
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

    /// The editor page handles these chords itself rather than handing them back.
    var editorHandles: Bool {
        switch self {
        case .editUndo, .editRedo, .editFind, .editFindNext, .editFindPrevious, .editComment: true
        default: false
        }
    }

    /// Chords the editor page gives back to the menu, so none is lost to the page.
    static var editorHostKeys: [(id: String, accel: String)] {
        allCases.compactMap { c in
            guard !c.editorHandles, let accel = c.macAccel else { return nil }
            return (c.rawValue, accel)
        }
    }
}

/// A sheet the workspace asks for a value with.
enum Prompt: String, Identifiable {
    case newFile, newFolder, gotoLine, gotoPage

    var id: String { rawValue }
}

/// What the menus ask of the PDF pane (`AppModel.requestPDF`).
enum PDFAction {
    case zoomIn, zoomOut, actualSize, fitWidth, fitHeight, goToPage(Int), find, inverseFromView, print, share

    /// Share… works on the file, whether or not the PDF shows.
    var showsPDF: Bool {
        if case .share = self { false } else { true }
    }
}

extension AppModel {
    /// `project` is nil on the projects screen or while Settings is in front.
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        switch command {
        // Undo and redo also serve text fields outside the editor.
        case .projectNew, .projectOpen, .filePageSetup, .editUndo, .editRedo: true
        case .editFind: project?.findAction(.showFindInterface) != nil
        case .editFindAndReplace: project?.findAction(.showReplaceInterface) != nil
        case .fileSave, .editFindNext, .editFindPrevious, .editBold, .editItalic, .editMath, .editComment, .editGotoLine:
            project?.editsText == true
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .compileStop: project?.compiling == true
        case .pdfSave, .filePrint, .pdfFind, .pdfGotoPage, .viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitHeight,
             .syncInverse:
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
        case .viewToggleProjectSettings: showProjectSettings ? "Hide Project Settings" : "Show Project Settings"
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
        case .fileNew: prompt = .newFile
        case .fileNewFolder: prompt = .newFolder
        case .fileUpload: addingFiles = true
        case .fileSave: Task { await project?.saveEdits() }
        case .pdfSave:
            if let project, let url = project.pdfURL {
                exporting = ExportFile(name: "\(project.id).pdf", type: .pdf) { url }
            }
        // AppKit: SwiftUI has no page setup panel.
        case .filePageSetup: NSApp.runPageLayout(nil)
        // The PDF, not the first responder (usually the editor's web view).
        case .filePrint: requestPDF(.print)
        case .editUndo: undo(redo: false, project)
        case .editRedo: undo(redo: true, project)
        // Chords from the editor page; the menu's own Find items are the
        // system's, which reach the window (`MainWindowController.performFindPanelAction`).
        case .editFind: project?.findAction(.showFindInterface)?()
        case .editFindAndReplace: project?.findAction(.showReplaceInterface)?()
        case .editFindNext: project?.findAction(.nextMatch)?()
        case .editFindPrevious: project?.findAction(.previousMatch)?()
        case .editBold: project?.format(.bold)
        case .editItalic: project?.format(.italic)
        case .editMath: project?.format(.math)
        case .editComment: project?.format(.comment)
        case .editGotoLine: prompt = .gotoLine
        case .pdfGotoPage: prompt = .gotoPage
        case .pdfFind: requestPDF(.find)
        case .viewToggleSidebar: sidebarVisible.toggle()
        case .viewTogglePdf: project?.showPDF.toggle()
        case .viewToggleProjectSettings: showProjectSettings.toggle()
        case .viewToggleLogs: project?.showLogs.toggle()
        case .viewToggleWordCount: showWordCount.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewActualSize: requestPDF(.actualSize)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitHeight: requestPDF(.fitHeight)
        case .compileRun: Task { await project?.compile() }
        case .compileStop: project?.stopCompile()
        // A Toggle bound to `autoCompile` in the menu.
        case .compileToggleAuto: break
        case .syncForward: Task { await project?.forwardSync() }
        case .syncInverse: requestPDF(.inverseFromView)
        }
    }

    /// A native text field keeps its own undo; otherwise CodeMirror's history,
    /// since WebKit's undo manager never sees CodeMirror's own changes.
    private func undo(redo: Bool, _ project: ProjectModel?) {
        // Every native field edits in an NSText field editor; SwiftUI has no
        // focused value that covers them all.
        let nativeText = NSApp.keyWindow?.firstResponder is NSText
        guard !nativeText, let project, project.editsText else { sendUndo(redo: redo); return }
        Task {
            // The page declines while one of its own fields has focus.
            if await project.editor.command(redo ? .redo : .undo) {
                project.editor.focus()
            } else {
                sendUndo(redo: redo)
            }
        }
    }

    private func sendUndo(redo: Bool) {
        _ = NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
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
        CommandGroup(replacing: .undoRedo) {
            item(.editUndo)
            item(.editRedo)
        }
        CommandGroup(replacing: .newItem) {
            item(.projectNew)
            item(.projectOpen)
            Menu("Open Recent") {
                ForEach(app.recents) { recent in
                    Button {
                        Task { await app.open(recent.id) }
                    } label: {
                        Label(recent.name, systemImage: "doc.text")
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
            // Not a MenuCommand: the web has no command id for it.
            Button("Share…") { app.requestPDF(.share) }
                .disabled(!(project?.hasPDF ?? false))
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
            SectionLevelItems(project: project)
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
            item(.viewToggleProjectSettings)
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
            Picker("Engine", selection: Binding<String?>(
                get: { project?.settings?.engine },
                set: { engine in
                    if let project, let engine { Task { await project.setEngine(engine) } }
                }
            )) {
                ForEach(texEngines, id: \.0) { id, title in Text(title).tag(Optional(id)) }
            }
            .disabled(project == nil)
            Divider()
            item(.syncForward)
            item(.syncInverse)
        }
    }
}
