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
    case editFindNext = "edit.findNext"
    case editFindPrevious = "edit.findPrevious"
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
        case .projectSearch: "Find in Project…"
        case .fileNew: "New File…"
        case .fileNewFolder: "New Folder…"
        case .fileUpload: "Add Files…"
        case .fileSave: "Save"
        case .pdfSave: "Save PDF As…"
        case .editUndo: "Undo"
        case .editRedo: "Redo"
        case .editFind: "Find and Replace…"
        case .editFindNext: "Find Next"
        case .editFindPrevious: "Find Previous"
        case .editBold: "Bold"
        case .editItalic: "Italic"
        case .editMath: "Inline Math"
        case .editComment: "Comment Selection"
        case .editGotoLine: "Go to Line…"
        case .pdfFind: "Find in PDF…"
        case .viewToggleSidebar: "Hide Sidebar"
        case .viewTogglePdf: "Hide PDF"
        case .viewToggleLogs: "Build Panel"
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
        case .editFindNext: "CmdOrCtrl+G"
        case .editFindPrevious: "CmdOrCtrl+Shift+G"
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

    /// Chords the editor page gives back to the menu. Undo, redo, find and
    /// comment stay with the editor, which implements them itself.
    static var editorHostKeys: [(id: String, accel: String)] {
        let editorOwned: Set<MenuCommand> = [.editUndo, .editRedo, .editFind, .editFindNext, .editFindPrevious, .editComment]
        return allCases.compactMap { c in
            guard !editorOwned.contains(c), let accel = c.accel else { return nil }
            return (c.rawValue, accel)
        }
    }
}

/// A sheet the workspace asks for a value with.
enum Prompt: String, Identifiable {
    case newFile, newFolder, gotoLine

    var id: String { rawValue }
}

enum PDFAction {
    case zoomIn, zoomOut, fitWidth, fitHeight, find, inverseFromView, print
}

extension AppModel {
    func isEnabled(_ command: MenuCommand) -> Bool {
        switch command {
        // Undo and redo also serve text fields outside the editor.
        case .projectNew, .editUndo, .editRedo, .compileToggleAuto: true
        case .fileSave, .editFind, .editFindNext, .editFindPrevious, .editBold, .editItalic, .editMath, .editComment, .editGotoLine:
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
        case .viewToggleLogs: project?.showLogs == true ? "Hide Build Panel" : "Show Build Panel"
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
        case .projectNew: newProject(); return
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
        case .editFindNext: findAgain(1, in: project)
        case .editFindPrevious: findAgain(-1, in: project)
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

    /// The first responder when it is a native text field's editor (the find
    /// field, a rename, the project search, the build log), not the editor's.
    private var nativeText: NSText? {
        guard let text = NSApp.keyWindow?.firstResponder as? NSText, !text.isDescendant(of: editor.webView) else { return nil }
        return text
    }

    /// A native text field keeps its own undo. Anything else — the editor, or
    /// a click on a toolbar button, which can take first responder from
    /// the web view — goes to CodeMirror's history: the standard undo: would
    /// reach WebKit's undo manager, which never sees CodeMirror's own changes
    /// (formatting, completions) and reverted half of an insertion.
    private func undo(redo: Bool) {
        guard nativeText == nil, project?.openPath != nil else { sendUndo(redo: redo); return }
        Task {
            // The page declines while one of its own fields, such as the
            // find panel's, has focus; that field's native undo takes it.
            if await editor.command(redo ? "redo" : "undo") {
                editor.focus()
            } else {
                sendUndo(redo: redo)
            }
        }
    }

    /// ⌘G steps the search being typed in. Other fields don't take the chord,
    /// so the menu gets it: a native one steps its own matches (Find in PDF,
    /// the build log's find bar) or leaves it be, rather than moving the
    /// editor's search behind it.
    private func findAgain(_ delta: Int, in project: ProjectModel) {
        if let text = nativeText {
            let owner = text.delegate as? NSView ?? text
            if let field = (owner as? NSTextField)?.delegate as? SearchField.Coordinator {
                field.field.step?(delta)
            } else if let log = findBarText(around: owner) {
                let sender = NSMenuItem()
                sender.tag = (delta > 0 ? NSTextFinder.Action.nextMatch : .previousMatch).rawValue
                log.performTextFinderAction(sender)
            }
            return
        }
        project.format(delta > 0 ? "findNext" : "findPrevious")
    }

    /// The text view whose find bar a view is part of, or is: the log's, as
    /// its find bar sits in its scroll view.
    private func findBarText(around view: NSView) -> NSTextView? {
        sequence(first: view, next: \.superview).lazy
            .compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }
            .first { $0.usesFindBar }
    }

    private func sendUndo(redo: Bool) {
        _ = NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
    }

    /// The project's window, even while Settings is key (it can be main
    /// too): the editor's, or, with the source pane hidden, the main window.
    private var documentWindow: NSWindow? { editor.webView.window ?? NSApp.mainWindow ?? NSApp.keyWindow }

    /// No starting folder: the panel opens where the user last saved, as
    /// every Mac app's Save As does.
    private func savePanel(name: String, type: UTType, _ write: @escaping @MainActor (URL) async -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard let window = documentWindow else { return }
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
        guard let window = documentWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await project.importFiles(urls) }
        }
    }
}

struct AppCommands: Commands {
    let app: AppModel
    @AppStorage(NavigatorView.outlineCollapsedKey) private var outlineCollapsed = false

    private func item(_ command: MenuCommand) -> some View {
        Button(app.title(command)) { app.perform(command) }
            .keyboardShortcut(app.shortcut(command))
            .disabled(!app.isEnabled(command))
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            item(.editUndo)
            item(.editRedo)
        }
        CommandGroup(replacing: .newItem) {
            item(.projectNew)
            // Mac only: the browser can't read a folder from disk.
            Button("Open…") { app.chooseProjectToOpen() }
                .keyboardShortcut("o")
            Divider()
            item(.fileNew)
            item(.fileNewFolder)
            item(.fileUpload)
        }
        // Replacing the save group drops the standard Close with it.
        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            item(.fileSave)
            Divider()
            item(.projectClose)
            Divider()
            // What makes a copy, then Share on its own, as Mac File menus
            // group them.
            item(.pdfSave)
            item(.projectExport)
            Divider()
            if let project = app.project, let url = project.pdfURL, project.pdfVersion > 0 {
                ShareLink("Share PDF", item: url)
            } else {
                Button("Share PDF") {}.disabled(true)
            }
        }
        // The standard Print would go to the first responder, usually the
        // editor's web view, and print the page rather than the PDF.
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { NSApp.runPageLayout(nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { app.requestPDF(.print) }
                .keyboardShortcut("p")
                .disabled(app.project?.pdfVersion ?? 0 == 0)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                item(.editFind)
                item(.editFindNext)
                item(.editFindPrevious)
                item(.projectSearch)
                item(.pdfFind)
            }
            item(.editGotoLine)
            // Replacing the group dropped the standard spelling items, which
            // the editor's native WebKit spell checking answers to. They go
            // down the responder chain, as AppKit's own do.
            Menu("Spelling and Grammar") {
                Button("Show Spelling and Grammar") { send(#selector(NSText.showGuessPanel(_:))) }
                    .keyboardShortcut(":", modifiers: .command)
                Button("Check Document Now") { send(#selector(NSText.checkSpelling(_:))) }
                    .keyboardShortcut(";", modifiers: .command)
            }
        }
        // Where Mac text apps keep styling (TextEdit, Pages): the toolbar's
        // centre group, and what its Insert menu holds.
        CommandGroup(replacing: .textFormatting) {
            item(.editBold)
            item(.editItalic)
            Divider()
            // Inline Math beside Display Math, after the line's level.
            InsertMenuItems(project: app.project, inlineMath: item(.editMath))
                .disabled(app.project?.openPath?.hasSuffix(".tex") != true)
            Divider()
            item(.editComment)
        }
        // The panes left to right, then the build panel below them.
        CommandGroup(after: .sidebar) {
            item(.viewToggleSidebar)
            // The sidebar's outline section, folded from its header too; here
            // it is a keyboard's and VoiceOver's way to it.
            Button(outlineCollapsed ? "Show File Outline" : "Hide File Outline") { outlineCollapsed.toggle() }
                .disabled(app.project?.openPath?.hasSuffix(".tex") != true || !app.sidebarVisible)
            item(.viewTogglePdf)
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(app.project == nil)
            item(.viewToggleLogs)
            Button(app.showWordCount ? "Hide Word Count" : "Show Word Count") { app.showWordCount.toggle() }
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
            Toggle(MenuCommand.compileToggleAuto.title, isOn: Bindable(app).autoCompile)
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
