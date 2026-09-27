import AppKit
import SwiftUI
import WebKit

/// The app's commands, with the browser version's ids and accelerators
/// (web/src/workspace.js `commandDefs`), then the Mac's own. The accelerator
/// string is the one source for both the menu's key equivalent and the
/// chords the embedded editor hands back to the menu.
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
    case viewToggleSidebar = "view.toggleSidebar"
    case viewTogglePdf = "view.togglePdf"
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

    /// The chord on the Mac: Apple's own where the shared table's differs,
    /// as Windows and the browser keep theirs. ⌃⌘S shows and hides the
    /// sidebar (HIG, The menu bar: View menu); ⌘0 is Actual Size, as in
    /// Preview, Safari and Pages, so fitting takes Preview's Zoom to Fit
    /// chord, ⌘9 (⌥⌘9 for the height, as ⌥ paired them before). ⌥⌘F is
    /// Find and Replace…, as in TextEdit and Xcode, so Find in PDF… has no
    /// chord: ⌘F finds in the PDF when it has the keyboard. The Mac's own
    /// commands take the HIG's chords (Keyboards): ⌥⌘I the inspector, ⌘.
    /// Stop, ⇧⌘P Page Setup….
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

    /// Chords the editor page gives back to the menu: every command's with
    /// one, so none is lost to the page. Undo, redo, find and comment stay
    /// with the editor, which implements them itself.
    static var editorHostKeys: [(id: String, accel: String)] {
        let editorOwned: Set<MenuCommand> = [.editUndo, .editRedo, .editFind, .editFindNext, .editFindPrevious, .editComment]
        return allCases.compactMap { c in
            guard !editorOwned.contains(c), let accel = c.macAccel else { return nil }
            return (c.rawValue, accel)
        }
    }
}

/// A sheet the workspace asks for a value with.
enum Prompt: String, Identifiable {
    case newFile, newFolder, gotoLine

    var id: String { rawValue }
}

/// What the menus ask of the PDF pane (`AppModel.requestPDF`).
enum PDFAction {
    case zoomIn, zoomOut, actualSize, fitWidth, fitHeight, find, inverseFromView, print
}

/// Edit › Find's items, done by the pane with the keyboard: what each does
/// there, or nil where it can't now, which turns the item off. A pane
/// publishes its own (`focusedValue(\.find, …)`); the source's stands in
/// for the rest of the window (`FindMenuResponder`).
typealias FindActions = (NSTextFinder.Action) -> (() -> Void)?

extension FocusedValues {
    @Entry var find: FindActions?
}

extension AppModel {
    /// `project` is the key window's (`AppCommands`), or the one a view in
    /// its window acts on; nil while the gallery or Settings is in front.
    func isEnabled(_ command: MenuCommand, on project: ProjectModel?) -> Bool {
        switch command {
        // Undo and redo also serve text fields outside the editor.
        case .projectNew, .projectOpen, .filePageSetup, .editUndo, .editRedo, .compileToggleAuto: true
        case .editFind: project?.findAction(.showFindInterface) != nil
        case .editFindAndReplace: project?.findAction(.showReplaceInterface) != nil
        case .fileSave, .editFindNext, .editFindPrevious, .editBold, .editItalic, .editMath, .editComment, .editGotoLine:
            project?.editsText == true
        case .compileRun: project.map { !$0.compiling && $0.texAvailable } ?? false
        case .compileStop: project?.compiling == true
        case .pdfSave, .filePrint, .pdfFind, .viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitHeight,
             .syncInverse:
            (project?.pdfVersion ?? 0) > 0
        case .syncForward: (project?.pdfVersion ?? 0) > 0 && project?.editsText == true
        default: project != nil
        }
    }

    /// Titles flip like native View-menu items, as the web's do.
    func title(_ command: MenuCommand, on project: ProjectModel?) -> String {
        switch command {
        case .viewToggleSidebar: sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        case .viewTogglePdf: project?.showPDF == false ? "Show PDF" : "Hide PDF"
        case .viewToggleInspector: showInspector ? "Hide Inspector" : "Show Inspector"
        case .viewToggleLogs: project?.showLogs == true ? "Hide Build Panel" : "Show Build Panel"
        case .viewToggleWordCount: showWordCount ? "Hide Word Count" : "Show Word Count"
        default: command.title
        }
    }

    /// In the gallery, with no files to make, ⌘N makes a project, as the
    /// web's home screen does (home.js).
    func shortcut(_ command: MenuCommand, on project: ProjectModel?) -> KeyboardShortcut? {
        switch (command, project) {
        case (.projectNew, nil): MenuCommand.shortcut(for: "CmdOrCtrl+N")
        case (.fileNew, nil): nil
        default: command.shortcut
        }
    }

    func perform(_ command: MenuCommand, on project: ProjectModel?) {
        guard isEnabled(command, on: project) else { return }
        switch command {
        case .projectNew: newProject()
        // Mac only: the browser can't read a folder from disk. The gallery
        // asks (`GalleryWindow`).
        case .projectOpen: openingProject = true
        // The menu closes the project's window, which closes the project
        // (`ProjectWindow`).
        case .projectClose: break
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
        // AppKit's: SwiftUI has no page setup panel.
        case .filePageSetup: NSApp.runPageLayout(nil)
        // The PDF, not the first responder, which the standard Print would
        // reach: usually the editor's web view, which printed the page.
        case .filePrint: requestPDF(.print)
        case .editUndo: undo(redo: false, project)
        case .editRedo: undo(redo: true, project)
        // The source's find; the menu's Find items are the system's, done
        // by the pane with the keyboard (`FindActions`).
        case .editFind: project?.findAction(.showFindInterface)?()
        case .editFindAndReplace: project?.findAction(.showReplaceInterface)?()
        case .editFindNext: project?.findAction(.nextMatch)?()
        case .editFindPrevious: project?.findAction(.previousMatch)?()
        case .editBold: project?.format("bold")
        case .editItalic: project?.format("italic")
        case .editMath: project?.format("math")
        case .editComment: project?.format("comment")
        case .editGotoLine: prompt = .gotoLine
        case .pdfFind: requestPDF(.find)
        case .viewToggleSidebar: sidebarVisible.toggle()
        case .viewTogglePdf: project?.showPDF.toggle()
        case .viewToggleInspector: showInspector.toggle()
        case .viewToggleLogs: project?.showLogs.toggle()
        case .viewToggleWordCount: showWordCount.toggle()
        case .viewZoomIn: requestPDF(.zoomIn)
        case .viewZoomOut: requestPDF(.zoomOut)
        case .viewActualSize: requestPDF(.actualSize)
        case .viewFitWidth: requestPDF(.fitWidth)
        case .viewFitHeight: requestPDF(.fitHeight)
        case .compileRun: Task { await project?.compile() }
        case .compileStop: project?.stopCompile()
        case .compileToggleAuto: autoCompile.toggle()
        case .syncForward: Task { await project?.forwardSync() }
        case .syncInverse: requestPDF(.inverseFromView)
        }
    }

    /// A native text field keeps its own undo. Anything else — the editor, or
    /// a click on a toolbar button, which can take first responder from
    /// the web view — goes to CodeMirror's history: the standard undo: would
    /// reach WebKit's undo manager, which never sees CodeMirror's own changes
    /// (formatting, completions) and reverted half of an insertion.
    private func undo(redo: Bool, _ project: ProjectModel?) {
        // A native field edits in AppKit's field editor, an NSText, as does
        // the build log: a type, not a focused value, as SwiftUI has none
        // for every field (a sheet's, the sidebar's search).
        let nativeText = NSApp.keyWindow?.firstResponder is NSText
        guard !nativeText, project?.editsText == true else { sendUndo(redo: redo); return }
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

    private func sendUndo(redo: Bool) {
        _ = NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
    }
}

struct AppCommands: Commands {
    let app: AppModel
    /// The key window's project, from its root (`WorkspaceView`): the menus
    /// act on the window in front, and are off in the gallery and Settings.
    @FocusedValue(ProjectModel.self) private var project
    @AppStorage(NavigatorView.outlineCollapsedKey) private var outlineCollapsed = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// `then` runs after the command, in the menu, which can open windows.
    private func item(_ command: MenuCommand, then: @escaping () -> Void = {}) -> some View {
        Button(app.title(command, on: project)) {
            app.perform(command, on: project)
            then()
        }
        .keyboardShortcut(app.shortcut(command, on: project))
        .disabled(!app.isEnabled(command, on: project))
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            item(.editUndo)
            item(.editRedo)
        }
        CommandGroup(replacing: .newItem) {
            // New Project… and Open… ask in the gallery, bringing it back
            // when it was closed, as Office's File menu does.
            item(.projectNew) { openWindow(id: AppScene.gallery) }
            item(.projectOpen) { openWindow(id: AppScene.gallery) }
            Menu("Open Recent") {
                ForEach(app.recentProjects.compactMap { id in app.projects.first { $0.id == id } }) { recent in
                    Button {
                        Task { await app.open(recent.id) }
                        openWindow(id: AppScene.project)
                    } label: {
                        Label(recent.name, systemImage: "doc.text")
                    }
                    // A project is an object, not an action: its icon shows,
                    // as the gallery's recents have it (HIG, Menus; macOS 27
                    // hides menu images otherwise).
                    .labelStyle(.titleAndIcon)
                }
                Divider()
                Button("Clear Menu") { app.recentProjects = [] }
                    .disabled(app.recentProjects.isEmpty)
            }
            Divider()
            item(.fileNew)
            item(.fileNewFolder)
            item(.fileUpload)
        }
        // After the system's Close (⌘W), as Apple's File menus order them.
        // Close Project closes the file and its window (HIG, Keyboards: a
        // file's close beside the window's).
        CommandGroup(after: .saveItem) {
            item(.fileSave)
            Divider()
            item(.projectClose) { dismissWindow(id: AppScene.project) }
            Divider()
            // What makes a copy, then Share on its own, as Mac File menus
            // group them; always there, off while there's no PDF.
            item(.pdfSave)
            item(.projectExport)
            Divider()
            // Opened at the bar's Share button (`ProjectModel.sharePDF`).
            Button("Share…") { project?.sharePDF() }
                .disabled(project.map { $0.pdfVersion == 0 || $0.pdfURL == nil } ?? true)
        }
        CommandGroup(replacing: .printItem) {
            item(.filePageSetup)
            item(.filePrint)
        }
        // The system's Find, Spelling and Grammar, Substitutions,
        // Transformations and Speech, each answered by whatever has the
        // keyboard: the editor's web view, a native field, or, for Find,
        // the pane (`FindActions`). A group of our own in their place would
        // lose the spelling and substitution toggles' checkmarks, which
        // only the system's items get.
        TextEditingCommands()
        CommandGroup(before: .textEditing) {
            item(.editGotoLine)
            Divider()
            // The searches of the app's own, beside the system's Find.
            item(.projectSearch)
            item(.pdfFind)
        }
        // The text's attributes, where Mac text apps keep styling (TextEdit,
        // Pages): the source bar's formatting, and the line's level.
        CommandGroup(replacing: .textFormatting) {
            item(.editBold)
            item(.editItalic)
            Divider()
            SectionLevelItems(project: project)
                .disabled(project?.isLaTeX != true)
            Divider()
            item(.editComment)
        }
        // The panes left to right, then the build panel below them.
        CommandGroup(after: .sidebar) {
            item(.viewToggleSidebar)
            // The sidebar's outline section, folded from its header too; here
            // it is a keyboard's and VoiceOver's way to it.
            Button(outlineCollapsed ? "Show File Outline" : "Hide File Outline") { outlineCollapsed.toggle() }
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
        // The app's own menus go between View and Window (HIG, The menu
        // bar): what the source bar inserts, as Pages' Insert menu, then
        // the build.
        CommandMenu("Insert") {
            InsertMenuItems(project: project, inlineMath: item(.editMath))
                .disabled(project?.isLaTeX != true)
        }
        CommandMenu("Compile") {
            item(.compileRun)
            item(.compileStop)
            Toggle(MenuCommand.compileToggleAuto.title, isOn: Bindable(app).autoCompile)
            Picker("Engine", selection: Binding(
                get: { project?.settings?.engine ?? defaultTeXEngine },
                set: { engine in
                    if let project { Task { await project.setEngine(engine) } }
                }
            )) {
                ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
            }
            .disabled(project == nil)
            Divider()
            item(.syncForward)
            item(.syncInverse)
        }
    }
}

/// Answers Edit › Find's items for a window. The system's items send
/// `performFindPanelAction:` down the responder chain, tagged with which
/// Find they are; SwiftUI's `onCommand` drops the tag. PDFView doesn't
/// answer it, so an AppKit responder after the window in the chain takes
/// what nothing in it answered, and hands it to the pane with the keyboard.
/// The editor's web view does answer it, in the view SwiftUI's `WebView`
/// wraps it in, with WebKit's own find bar, which searches only the lines
/// CodeMirror has drawn, so its Replace All missed the rest; `findDisabled`
/// doesn't turn it off (macOS 27.2). So a second responder goes between
/// the web view and that wrapper whenever the web view takes the keyboard.
/// A find bar's field passes the items on too (`SearchField`); the build
/// log's text view answers them itself.
struct FindMenuResponder: NSViewRepresentable {
    let find: FindActions

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.responder.find = find
        anchor.webResponder.find = find
    }

    /// Puts the responder after the window it's in, and takes it out again.
    final class Anchor: NSView {
        let responder = Responder()
        let webResponder = Responder()
        private weak var chained: NSWindow?
        private weak var web: WKWebView?
        private var focus: NSKeyValueObservation?

        // Not there to click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== chained else { return }
            if let chained {
                // Wherever it is now: something may have joined after it.
                var link: NSResponder = chained
                while let next = link.nextResponder, next !== responder { link = next }
                if link.nextResponder === responder { link.nextResponder = responder.nextResponder }
            }
            if let web, web.nextResponder === webResponder { web.nextResponder = webResponder.nextResponder }
            chained = window
            focus = nil
            if let window {
                responder.nextResponder = window.nextResponder
                window.nextResponder = responder
                focus = window.observe(\.firstResponder, options: .initial) { [weak self] window, _ in
                    MainActor.assumeIsolated { self?.front(window.firstResponder) }
                }
            }
        }

        /// In front of the web view's wrapper, once per time it's hosted:
        /// moving it to another view resets its next responder.
        private func front(_ first: NSResponder?) {
            guard let web = first as? WKWebView, web.nextResponder !== webResponder else { return }
            webResponder.nextResponder = web.nextResponder
            web.nextResponder = webResponder
            self.web = web
        }
    }

    final class Responder: NSResponder, NSMenuItemValidation {
        var find: FindActions?

        @objc func performFindPanelAction(_ sender: Any?) {
            action(for: sender)?()
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            item.action != #selector(performFindPanelAction(_:)) || action(for: item) != nil
        }

        /// The item's tag is the `NSTextFinder.Action` it asks for.
        private func action(for sender: Any?) -> (() -> Void)? {
            guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
                  let action = NSTextFinder.Action(rawValue: tag) else { return nil }
            return find?(action)
        }
    }
}
