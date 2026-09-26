import SwiftUI

/// An open project: files and outline in the sidebar; the source beside its
/// PDF, with a panel for the build below; and an inspector on the trailing
/// edge.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            NavigatorView(project: project)
                .navigationSplitViewColumnWidth(min: Metrics.sidebarWidth.lowerBound, ideal: Metrics.sidebarIdeal,
                                                max: Metrics.sidebarWidth.upperBound)
        } detail: {
            SplitController(app: app, axis: .horizontal, autosave: "InspectorSplit", panes: [
                SplitPane(minimum: Metrics.editorsMinWidth) { EditorArea(project: project) },
                SplitPane(minimum: Metrics.inspectorWidth.lowerBound, maximum: Metrics.inspectorWidth.upperBound,
                          fraction: 0.28, keepsSize: true, shown: app.showInspector, glass: true) {
                    InspectorView(project: project)
                },
            ])
            // Built once per project: its panes keep the views they were made with.
            .id(ObjectIdentifier(project))
            .frame(minWidth: Metrics.editorsMinWidth, minHeight: 280)
            // On the detail, as Apple's Landmarks sample has it: on the split
            // view itself the spacers were dropped and every item ran
            // together in one pill.
            .toolbar(id: WorkspaceToolbar.id) { WorkspaceToolbar(app: app, project: project) }
            .toolbar(removing: .title)
        }
        .navigationTitle(project.openPath.map { ($0 as NSString).lastPathComponent } ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        // The open file as the window's represented document, none rather
        // than the disk's root while no file is open. With the toolbar's
        // title removed there is no proxy icon or path menu; the Window menu
        // still shows the file.
        // From a background, so the workspace keeps its identity (and its
        // panes) as the document comes and goes.
        .background {
            if let url = project.openURL { Color.clear.navigationDocument(url) }
        }
        .sheet(item: $app.prompt) { prompt in
            switch prompt {
            case .newFile: NewEntrySheet(project: project, directory: false)
            case .newFolder: NewEntrySheet(project: project, directory: true)
            case .gotoLine: GoToLineSheet(project: project)
            }
        }
        // The open file changed on disk while it has edits here.
        .alert(project.diskConflict.map { "“\(($0 as NSString).lastPathComponent)” Changed on Disk" } ?? "",
               isPresented: Binding(presenting: $project.diskConflict), presenting: project.diskConflict) { _ in
            Button("Keep Editing", role: .cancel) { project.keepEdits() }
            // It discards the edits here: never the default button.
            Button("Revert", role: .destructive) { Task { await project.revertToDisk() } }
        } message: { path in
            Text("Another app changed \(path) while it has unsaved changes here. Revert to the version on disk, or keep editing and save over it.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { note in
            guard let toolbar = (note.object as? NSWindow)?.toolbar, toolbar.identifier == WorkspaceToolbar.id
            else { return }
            toolbar.keepIconsOnly()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // This window's only: closing Settings is no reason to save.
            guard (note.object as? NSWindow) === app.editor.webView.window else { return }
            Task { await project.flush() }
        }
    }

    /// The columns' widths. The sidebar's ideal is the UI kit's window
    /// sidebar; the window's own minimum (960 × 600) is set once, in the app.
    private enum Metrics {
        static let sidebarWidth: ClosedRange<CGFloat> = 200...320
        static let sidebarIdeal: CGFloat = 256
        /// The source and the PDF, side by side at their smallest.
        static let editorsMinWidth: CGFloat = 441
        static let inspectorWidth: ClosedRange<CGFloat> = 220...320
    }

}

/// File › New File… and New Folder…: a name, and the folder to make it in
/// (the open file's to begin with), as a Save sheet asks.
private struct NewEntrySheet: View {
    let project: ProjectModel
    let directory: Bool
    @State private var name: String
    @State private var folder: String
    @FocusState private var nameFocused: Bool

    init(project: ProjectModel, directory: Bool) {
        self.project = project
        self.directory = directory
        _name = State(initialValue: directory ? "untitled folder" : "untitled.tex")
        _folder = State(initialValue: (project.openPath.map { ($0 as NSString).deletingLastPathComponent }) ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: directory ? "New Folder" : "New File", action: "Create",
                    enabled: !trimmed.isEmpty && !trimmed.hasPrefix("/")) {
            let path = folder.isEmpty ? trimmed : "\(folder)/\(trimmed)"
            Task { await project.createEntry(path, directory: directory) }
        } fields: {
            TextField("Name", text: $name)
                .focused($nameFocused)
            Picker("Where", selection: $folder) {
                Label(project.id, systemImage: "folder").tag("")
                ForEach(folders(project.tree), id: \.self) { path in
                    Label(path, systemImage: "folder").tag(path)
                }
            }
        }
        .onAppear { nameFocused = true }
    }

    private func folders(_ nodes: [TreeNode]) -> [String] {
        nodes.filter(\.isDirectory).flatMap { [$0.path] + folders($0.children ?? []) }
    }
}

/// Edit › Go to Line…: a line of the open file.
private struct GoToLineSheet: View {
    let project: ProjectModel
    @State private var text = ""

    private var lines: Int? { project.counts?.lines }

    private var line: Int? {
        guard let line = Int(text.trimmingCharacters(in: .whitespaces)), line >= 1 else { return nil }
        return lines.map { min(line, $0) } ?? line
    }

    var body: some View {
        DialogSheet(title: "Go to Line", action: "Go", enabled: line != nil) {
            if let line { project.reveal(line: line) }
        } fields: {
            TextField("Line", text: $text, prompt: Text(lines.map { "1–\($0)" } ?? "Line number"))
        }
    }
}

/// The window toolbar, as Pages', Keynote's and Xcode's: back at the
/// leading edge, the source's tools over the source, then Compile, zoom and
/// Share over the PDF at the trailing edge, with the panes' toggles. The
/// system sizes it, gives each group its glass and folds what doesn't fit
/// into its » menu; View › Customize Toolbar… arranges it, as Notes' does.
/// Every item is in the menu bar too.
///
/// No title in it (Notes' pattern): the location row under it names the
/// project and file, and a shown title takes all the toolbar's free room,
/// which pushed the source's tools over the PDF. The window keeps its
/// title and subtitle for the Window menu and Mission Control; the title
/// bar's proxy icon, path menu and "Edited" go with the title (the status
/// bar says Edited / Saved).
///
/// The PDF's group sits trailing rather than following the source | PDF
/// divider: that takes an `NSTrackingSeparatorToolbarItem`, which SwiftUI
/// has no item for, and adding one means taking over SwiftUI's own toolbar
/// delegate. With the inspector shown, Compile and zoom sit over it.
///
/// No two `ControlGroup` items side by side: their capsules melt into one
/// shape with a neck between them, so the text styles and math are one
/// group, and a fixed space parts zoom from Share.
struct WorkspaceToolbar: CustomizableToolbarContent {
    static let id = "workspace"

    /// The items, in their default order.
    enum Item: String, CaseIterable {
        case back, undoRedo, sectionLevel, format, symbols, references, figures, lists, insert
        case compile, zoom, share, pdf, inspector
    }

    /// In Customize Toolbar… but not shown at first: they are in the Insert
    /// menu, and with them the toolbar overflowed at the default size.
    static let hiddenByDefault: Set<Item> = [.references, .figures, .lists]

    /// The last to fold into the » menu as the window narrows: the
    /// window's primary action and the panes' toggles, as the HIG keeps
    /// trailing items in view.
    static let essentials: Set<Item> = [.compile, .pdf, .inspector]

    let app: AppModel
    let project: ProjectModel

    var body: some CustomizableToolbarContent {
        // Back to the projects, as the web's and Windows' title bars lead
        // with it; File › Close Project too. Navigation, so not movable.
        ToolbarItem(id: Item.back.rawValue, placement: .navigation) {
            Button { app.perform(.projectClose) } label: {
                Label("Projects", systemImage: "chevron.backward")
            }
            .help("Back to Projects")
        }
        .customizationBehavior(.disabled)

        sourceTools
        ToolbarSpacer(.flexible)
        // Once items fold into », AppKit packs the rest from the leading
        // edge and the flexible space takes nothing: this keeps Compile
        // apart from the source's tools there.
        ToolbarSpacer(.fixed)
        pdfTools
        ToolbarSpacer(.fixed)
        item(.pdf) { PDFToggle(project: project) }
        item(.inspector) { InspectorToggle() }
    }

    /// Over the source. (A builder block takes ten items with the macOS
    /// 26 SDK, hence the groups.)
    @ToolbarContentBuilder
    private var sourceTools: some CustomizableToolbarContent {
        item(.undoRedo) { UndoRedoTools() }
        item(.sectionLevel) { SectionLevelMenu(project: project) }
        item(.format) { FormatTools(project: project) }
        item(.symbols) { SymbolsTool(project: project) }
        item(.references) { TemplateTools(kind: .references, project: project) }
        item(.figures) { TemplateTools(kind: .figures, project: project) }
        item(.lists) { TemplateTools(kind: .lists, project: project) }
        item(.insert) { InsertTool(project: project) }
    }

    /// Over the PDF.
    @ToolbarContentBuilder
    private var pdfTools: some CustomizableToolbarContent {
        item(.compile) { CompileTool(project: project) }
        // Apart, so the tinted glass doesn't tint the zoom group's rim.
        ToolbarSpacer(.fixed)
        item(.zoom) { ZoomTools(project: project) }
        // Apart, or the zoom group's glass runs into Share's.
        ToolbarSpacer(.fixed)
        item(.share) { ShareTool(project: project) }
    }

    private func item(_ item: Item, @ViewBuilder content: () -> some View) -> some CustomizableToolbarContent {
        ToolbarItem(id: item.rawValue) { content() }
            .defaultCustomization(Self.hiddenByDefault.contains(item) ? .hidden : .automatic)
            .keptInView(Self.essentials.contains(item))
    }
}

extension NSToolbar {
    /// Icons only, the macOS 26+ default, and not offered as a choice in
    /// Customize Toolbar…: under Icon and Text AppKit drew the labels of a
    /// `ControlGroup`'s members (Bold, Zoom In…) as disabled while they were
    /// enabled, as SwiftUI's members have no action for AppKit to validate,
    /// and re-setting their state didn't hold. Checked on each window update,
    /// as SwiftUI makes the toolbar after the window.
    func keepIconsOnly() {
        guard allowsDisplayModeCustomization || displayMode != .iconOnly else { return }
        allowsDisplayModeCustomization = false
        displayMode = .iconOnly
    }
}

extension CustomizableToolbarContent {
    /// The item folds into the toolbar's » menu after the others. SwiftUI's
    /// `visibilityPriority` (macOS 26.1) is declared from the macOS 27 SDK
    /// (Swift 6.4) on; with CI's 26.5 SDK the toolbar folds from its end.
    /// AppKit's own priority can't stand in: SwiftUI resets it on update.
    func keptInView(_ kept: Bool) -> some CustomizableToolbarContent {
        #if compiler(>=6.4)
        visibilityPriority(kept ? .high : .automatic)
        #else
        self
        #endif
    }
}

/// Shows and hides the PDF, as View › Hide PDF does. A plain button whose
/// title says what it will do, as the sidebar's toggle and Xcode's
/// inspector button are: a toggle draws its on state accent-filled, and
/// Compile is the toolbar's one tinted control.
private struct PDFToggle: View {
    @Bindable var project: ProjectModel

    var body: some View {
        let title = project.showPDF ? "Hide PDF" : "Show PDF"
        Button(title, systemImage: "doc.richtext") { project.showPDF.toggle() }
            .help(title)
    }
}

/// Shows and hides the inspector, as View › Hide Inspector does.
private struct InspectorToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let title = app.showInspector ? "Hide Inspector" : "Show Inspector"
        Button(title, systemImage: "sidebar.right") { app.showInspector.toggle() }
            .help(title)
    }
}

/// The Format menu's LaTeX tools, as the toolbar offers them: the line's
/// section level, math and symbols, references, then what inserts a block.
struct InsertMenuItems<InlineMath: View>: View {
    let project: ProjectModel?
    /// The menu bar's Inline Math item, with its shortcut.
    let inlineMath: InlineMath

    var body: some View {
        Menu("Section Level") {
            ForEach(headingLevels, id: \.1) { title, command in
                Button(title) { project?.format("heading", command) }
            }
        }
        inlineMath
        Button("Display Math") { project?.format("displayMath") }
        SymbolMenu(project: project)
        Menu("Reference") {
            ForEach(referenceTemplates, id: \.0) { label, template in
                Button(label) { project?.format("inline", template) }
            }
        }
        Divider()
        ForEach(insertTemplates, id: \.0) { label, template in
            Button(label) { project?.format("insert", template) }
        }
        Menu("List") {
            ForEach(listTemplates, id: \.0) { label, template in
                Button(label) { project?.format("insert", template) }
            }
        }
    }
}

/// The engines a project can compile with, for the compile menu and Settings.
let texEngines = [("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX")]

/// web/src/sourcebar.js `INSERT_TEMPLATES` (the lists are `listTemplates`);
/// "$0" marks where the cursor lands. The toolbar finds them by title
/// (`ProjectModel.insert`). Titles are menu items here, so title case
/// without the web's parenthetical: "Aligned Equations" is the web's
/// "Align (multi-line math)".
let insertTemplates: [(String, String)] = [
    ("Figure", "\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n"),
    ("Table", "\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n"),
    ("Equation", "\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n"),
    ("Aligned Equations", "\\begin{align}\n  $0 \\\\\n\\end{align}\n"),
    ("Code Block", "\\begin{verbatim}\n$0\n\\end{verbatim}\n"),
]

/// The trailing inspector: the project's build settings, then facts about
/// the open file and the PDF — what the web kept in its settings popover and
/// status line, gathered where a Mac app keeps them.
struct InspectorView: View {
    @Bindable var project: ProjectModel

    var body: some View {
        Form {
            Section("Project") {
                Picker("Main File", selection: Binding(
                    get: { project.settings?.mainFile ?? "" },
                    set: { path in Task { await project.setMainFile(path) } }
                )) {
                    ForEach(texFiles(project.tree), id: \.self) { Text($0).tag($0) }
                }
                Picker("Engine", selection: Binding(
                    get: { project.settings?.engine ?? "pdflatex" },
                    set: { engine in Task { await project.setEngine(engine) } }
                )) {
                    ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(isOn: Binding(
                    get: { project.settings?.shellEscape ?? false },
                    set: { on in Task { await project.setShellEscape(on) } }
                )) {
                    Text("Shell Escape")
                    Text("Lets packages such as minted run programs. Only for projects you trust.")
                }
            }
            .disabled(project.settings == nil)

            if let path = project.openPath {
                Section("Document") {
                    LabeledContent("Name", value: (path as NSString).lastPathComponent)
                    LabeledContent("Folder", value: folder(of: path))
                    if let counts = project.counts {
                        LabeledContent("Words", value: counts.words.formatted())
                        LabeledContent("Lines", value: counts.lines.formatted())
                    }
                    if !project.outline.isEmpty {
                        LabeledContent("Sections", value: project.outline.count.formatted())
                    }
                }
            }

            Section("Build") {
                if let result = project.result {
                    LabeledContent("Last Build", value: result.ok ? "Succeeded" : "Failed")
                    LabeledContent("Duration") {
                        Text(result.durationText).monospacedDigit()
                    }
                    LabeledContent("Errors", value: project.errorCount.formatted())
                    LabeledContent("Warnings", value: project.warningCount.formatted())
                } else {
                    // The status bar's phrase, shortened to fit beside its
                    // label in a narrow inspector.
                    LabeledContent("Last Build", value: project.pdfVersion > 0 ? "None Yet" : "None")
                }
                if let freshness = project.pdfFreshness {
                    Label(freshness.title, systemImage: freshness.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // The pane's glass shows through, as an inspector's does.
        .scrollContentBackground(.hidden)
    }

    private func folder(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? project.id : dir
    }

    private func texFiles(_ nodes: [TreeNode]) -> [String] {
        nodes.flatMap { node in
            node.isDirectory ? texFiles(node.children ?? []) : (node.path.hasSuffix(".tex") ? [node.path] : [])
        }
    }
}
