import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's commands, with the browser version's ids and accelerators
/// (web/src/workspace.js `commandDefs`). The accelerator string is the one
/// source for both the menu's key equivalent and the chords the embedded
/// editor hands back to the menu.
enum MenuCommand: String, CaseIterable {
    case projectNew = "project.new"
    case projectClose = "project.close"
    case projectExport = "project.export"
    case projectSearch = "project.search"
    case fileNew = "file.new"
    case fileNewFolder = "file.newFolder"
    case fileUpload = "file.upload"
    case fileSave = "file.save"
    case pdfSave = "pdf.save"
    case editUndo = "edit.undo"
    case editRedo = "edit.redo"
    case editFind = "edit.find"
    case editBold = "edit.bold"
    case editItalic = "edit.italic"
    case editMath = "edit.math"
    case editComment = "edit.comment"
    case editGotoLine = "edit.gotoLine"
    case pdfFind = "pdf.find"
    case viewToggleSidebar = "view.toggleSidebar"
    case viewTogglePdf = "view.togglePdf"
    case viewToggleLogs = "view.toggleLogs"
    case viewZoomIn = "view.zoomIn"
    case viewZoomOut = "view.zoomOut"
    case viewFitWidth = "view.fitWidth"
    case viewFitHeight = "view.fitHeight"
    case compileRun = "compile.run"
    case compileToggleAuto = "compile.toggleAuto"
    case syncForward = "sync.forward"
    case syncInverse = "sync.inverse"

    var title: String {
        switch self {
        case .projectNew: "New Project…"
        case .projectClose: "Close Project"
        case .projectExport: "Export Project as ZIP…"
        case .projectSearch: "Find in Project"
        case .fileNew: "New File…"
        case .fileNewFolder: "New Folder…"
        case .fileUpload: "Add Files…"
        case .fileSave: "Save"
        case .pdfSave: "Save PDF As…"
        case .editUndo: "Undo"
        case .editRedo: "Redo"
        case .editFind: "Find & Replace"
        case .editBold: "Bold"
        case .editItalic: "Italic"
        case .editMath: "Inline Math"
        case .editComment: "Toggle Comment"
        case .editGotoLine: "Go to Line…"
        case .pdfFind: "Find in PDF…"
        case .viewToggleSidebar: "Hide Sidebar"
        case .viewTogglePdf: "Hide PDF"
        case .viewToggleLogs: "Build Log"
        case .viewZoomIn: "Zoom In"
        case .viewZoomOut: "Zoom Out"
        case .viewFitWidth: "Fit Width"
        case .viewFitHeight: "Fit Height"
        case .compileRun: "Compile"
        case .compileToggleAuto: "Compile Automatically"
        case .syncForward: "Go to PDF Position"
        case .syncInverse: "Go to Source Position"
        }
    }

    var accel: String? {
        switch self {
        case .projectNew: "CmdOrCtrl+Shift+N"
        case .projectSearch: "CmdOrCtrl+Shift+F"
        case .fileNew: "CmdOrCtrl+N"
        case .fileNewFolder: "CmdOrCtrl+Shift+Alt+N"
        case .fileSave: "CmdOrCtrl+S"
        case .pdfSave: "CmdOrCtrl+Shift+S"
        case .editUndo: "CmdOrCtrl+Z"
        case .editRedo: "CmdOrCtrl+Shift+Z"
        case .editFind: "CmdOrCtrl+F"
        case .editBold: "CmdOrCtrl+B"
        case .editItalic: "CmdOrCtrl+I"
        case .editMath: "CmdOrCtrl+Shift+M"
        case .editComment: "CmdOrCtrl+/"
        case .editGotoLine: "CmdOrCtrl+L"
        case .pdfFind: "CmdOrCtrl+Alt+F"
        case .viewToggleSidebar: "CmdOrCtrl+\\"
        case .viewTogglePdf: "CmdOrCtrl+Shift+\\"
        case .viewToggleLogs: "CmdOrCtrl+Shift+L"
        case .viewZoomIn: "CmdOrCtrl+Plus"
        case .viewZoomOut: "CmdOrCtrl+Minus"
        case .viewFitWidth: "CmdOrCtrl+0"
        case .viewFitHeight: "CmdOrCtrl+Alt+0"
        case .compileRun: "CmdOrCtrl+Return"
        case .syncForward: "Ctrl+Return"
        case .syncInverse: "Ctrl+Shift+Return"
        default: nil
        }
    }

    var shortcut: KeyboardShortcut? {
        accel.flatMap(Self.shortcut(for:))
    }

    /// "CmdOrCtrl+Shift+Z" → ⇧⌘Z.
    static func shortcut(for accel: String) -> KeyboardShortcut? {
        var parts = accel.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast() else { return nil }
        var modifiers: EventModifiers = []
        for part in parts {
            switch part {
            case "CmdOrCtrl", "Cmd", "Command": modifiers.insert(.command)
            case "Ctrl", "Control": modifiers.insert(.control)
            case "Alt", "Option": modifiers.insert(.option)
            case "Shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let equivalent: KeyEquivalent
        switch key {
        case "Return", "Enter": equivalent = .return
        case "Plus": equivalent = "="
        case "Minus": equivalent = "-"
        default:
            guard key.count == 1, let c = key.lowercased().first else { return nil }
            equivalent = KeyEquivalent(c)
        }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// Chords the editor page gives back to the menu. Undo, redo, find and
    /// comment stay with the editor, which implements them itself.
    static var editorHostKeys: [(id: String, accel: String)] {
        let editorOwned: Set<MenuCommand> = [.editUndo, .editRedo, .editFind, .editComment]
        return allCases.compactMap { c in
            guard !editorOwned.contains(c), let accel = c.accel else { return nil }
            return (c.rawValue, accel)
        }
    }
}

enum Prompt: Identifiable {
    case newFile, newFolder, gotoLine
    case renameEntry(String)
    case renameProject(ProjectInfo)

    var id: String {
        switch self {
        case .newFile: "newFile"
        case .newFolder: "newFolder"
        case .gotoLine: "gotoLine"
        case .renameEntry(let path): "rename:\(path)"
        case .renameProject(let p): "renameProject:\(p.id)"
        }
    }
}

enum PDFAction {
    case zoomIn, zoomOut, fitWidth, fitHeight, find, inverseFromView
}

extension AppModel {
    func isEnabled(_ command: MenuCommand) -> Bool {
        switch command {
        // Undo and redo also serve text fields outside the editor.
        case .projectNew, .editUndo, .editRedo, .compileToggleAuto: true
        case .fileSave, .editFind, .editBold, .editItalic, .editMath, .editComment, .editGotoLine:
            project?.openPath != nil
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .pdfSave, .pdfFind, .viewZoomIn, .viewZoomOut, .viewFitWidth, .viewFitHeight, .syncInverse:
            project?.pdfVersion ?? 0 > 0
        case .syncForward: (project?.pdfVersion ?? 0) > 0 && project?.openPath != nil
        default: project != nil
        }
    }

    /// Titles flip like native View-menu items, as the web's do.
    func title(_ command: MenuCommand) -> String {
        switch command {
        case .viewToggleSidebar: sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        case .viewTogglePdf: project?.showPDF == false ? "Show PDF" : "Hide PDF"
        default: command.title
        }
    }

    /// On the home screen, with no files to make, ⌘N makes a project, as the
    /// web's home screen does (home.js).
    func shortcut(_ command: MenuCommand) -> KeyboardShortcut? {
        switch (command, project) {
        case (.projectNew, nil): MenuCommand.shortcut(for: "CmdOrCtrl+N")
        case (.fileNew, nil): nil
        default: command.shortcut
        }
    }

    func perform(_ command: MenuCommand) {
        guard isEnabled(command) else { return }
        switch command {
        case .projectNew: showNewProject = true; return
        case .editUndo: undo(redo: false); return
        case .editRedo: undo(redo: true); return
        case .compileToggleAuto: autoCompile.toggle(); return
        default: break
        }
        guard let project else { return }
        switch command {
        case .projectNew, .editUndo, .editRedo, .compileToggleAuto: break
        case .projectClose: Task { await close() }
        case .projectExport:
            savePanel(name: "\(project.id).zip", type: .zip) { url in await project.exportZip(to: url) }
        case .projectSearch:
            sidebarVisible = true
            searchFocusToken += 1
        case .fileNew: prompt = .newFile
        case .fileNewFolder: prompt = .newFolder
        case .fileUpload: importPanel(into: project)
        case .fileSave: Task { await project.saveEdits() }
        case .pdfSave:
            savePanel(name: "\(project.id).pdf", type: .pdf) { url in await project.savePDF(to: url) }
        case .editFind: project.format("find")
        case .editBold: project.format("bold")
        case .editItalic: project.format("italic")
        case .editMath: project.format("math")
        case .editComment: project.format("comment")
        case .editGotoLine: prompt = .gotoLine
        case .pdfFind: requestPDF(.find)
        case .viewToggleSidebar: sidebarVisible.toggle()
        case .viewTogglePdf: project.showPDF.toggle()
        case .viewToggleLogs: project.showLogs.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitHeight: requestPDF(.fitHeight)
        case .compileRun: Task { await project.compile() }
        case .syncForward: Task { await project.forwardSync() }
        case .syncInverse: requestPDF(.inverseFromView)
        }
    }

    /// Undo and redo go to CodeMirror's own history while the editor has
    /// focus, and down the responder chain — to a text field's — otherwise.
    /// The standard items would ask WebKit's undo manager, which never sees
    /// the changes CodeMirror makes itself (formatting, completions).
    private func undo(redo: Bool) {
        if let view = NSApp.keyWindow?.firstResponder as? NSView, view.isDescendant(of: editor.webView) {
            // The page declines while one of its own fields, such as the
            // find panel's, has focus; that field's native undo takes it.
            Task {
                if !(await editor.command(redo ? "redo" : "undo")) { sendUndo(redo: redo) }
            }
        } else {
            sendUndo(redo: redo)
        }
    }

    private func sendUndo(redo: Bool) {
        _ = NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
    }

    private func savePanel(name: String, type: UTType, _ write: @escaping @MainActor (URL) async -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await write(url) }
        }
    }

    private func importPanel(into project: ProjectModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await project.importFiles(urls) }
        }
    }
}

struct AppCommands: Commands {
    let app: AppModel

    private func item(_ command: MenuCommand) -> some View {
        Button(app.title(command)) { app.perform(command) }
            .keyboardShortcut(app.shortcut(command))
            .disabled(!app.isEnabled(command))
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            item(.editUndo)
            item(.editRedo)
        }
        CommandGroup(replacing: .newItem) {
            item(.projectNew)
            Divider()
            item(.fileNew)
            item(.fileNewFolder)
            item(.fileUpload)
        }
        CommandGroup(replacing: .saveItem) {
            item(.fileSave)
            Divider()
            item(.projectClose)
            Divider()
            item(.pdfSave)
            item(.projectExport)
        }
        CommandGroup(replacing: .textEditing) {
            item(.editFind)
            item(.projectSearch)
            item(.pdfFind)
            item(.editGotoLine)
            Divider()
            item(.editBold)
            item(.editItalic)
            item(.editMath)
            item(.editComment)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Inspector", isOn: Binding(get: { app.showInspector }, set: { app.showInspector = $0 }))
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(app.project == nil)
            Divider()
            item(.viewToggleSidebar)
            item(.viewTogglePdf)
            Toggle(MenuCommand.viewToggleLogs.title, isOn: Binding(
                get: { app.project?.showLogs ?? false },
                set: { app.project?.showLogs = $0 }
            ))
            .keyboardShortcut(MenuCommand.viewToggleLogs.shortcut)
            .disabled(app.project == nil)
            Divider()
            item(.viewZoomIn)
            item(.viewZoomOut)
            item(.viewFitWidth)
            item(.viewFitHeight)
            Divider()
        }
        CommandMenu("Compile") {
            item(.compileRun)
            Button("Stop") { app.project?.stopCompile() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(app.project?.compiling != true)
            Toggle(MenuCommand.compileToggleAuto.title, isOn: Binding(
                get: { app.autoCompile },
                set: { app.autoCompile = $0 }
            ))
            Picker("Engine", selection: Binding(
                get: { app.project?.settings?.engine ?? "pdflatex" },
                set: { engine in
                    if let project = app.project { Task { await project.setEngine(engine) } }
                }
            )) {
                ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
            }
            .disabled(app.project == nil)
            Divider()
            item(.syncForward)
            item(.syncInverse)
        }
    }
}
