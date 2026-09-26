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
            .toolbar { toolbar }
        }
        .navigationTitle(project.openPath.map { ($0 as NSString).lastPathComponent } ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        // The open file as the window's represented document (proxy icon and
        // path menu), none rather than the disk's root while no file is open.
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // This window's only: closing Settings is no reason to save.
            guard (note.object as? NSWindow) === NSApp.projectWindow else { return }
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

    // ---------- toolbar ----------

    /// Back and the file as the window's title at the leading edge, and the
    /// panes' toggles at the trailing. What acts on a pane sits over it
    /// instead: editing over the source (EditorView's `SourceBar`), compiling
    /// and sharing over the PDF (PDFPane's bar). Every item is in the menu
    /// bar too.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Back to the projects, as the web's and Windows' title bars lead
        // with it; otherwise only File › Close Project left a project.
        ToolbarItem(placement: .navigation) {
            Button { app.perform(.projectClose) } label: {
                Label("Projects", systemImage: "chevron.backward")
            }
            .help("Back to Projects")
        }

        // The panes' toggles, sharing one piece of glass as related buttons
        // do. Nothing here acts on the PDF alone: Share is the PDF bar's.
        ToolbarItem(placement: .primaryAction) { PDFToggle(project: project) }
        ToolbarItem(placement: .primaryAction) { InspectorToggle() }
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

/// Shows and hides the PDF, as View › Hide PDF does. A plain button whose
/// title says what it will do, as the sidebar's toggle and Xcode's
/// inspector button are: a toggle draws its on state accent-filled, which
/// made the two toggles the toolbar's loudest controls.
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

/// The Format menu's LaTeX tools, as the source bar offers them: the line's
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
/// "$0" marks where the cursor lands. The source bar finds them by title
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
        // Label-and-value rows straight on the pane's glass, as Xcode's
        // inspector has them: a bold title per section, a hairline between
        // sections, labels right-aligned in one column. Grouped boxes read
        // as a layer of their own on glass.
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: BarMetrics.groupSpacing,
                 verticalSpacing: BarMetrics.groupSpacing) {
                header("Project")
                GridRow {
                    label("Main File")
                    Picker("Main File", selection: Binding(
                        get: { project.settings?.mainFile ?? "" },
                        set: { path in Task { await project.setMainFile(path) } }
                    )) {
                        ForEach(texFiles(project.tree), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label("Engine")
                    Picker("Engine", selection: Binding(
                        get: { project.settings?.engine ?? "pdflatex" },
                        set: { engine in Task { await project.setEngine(engine) } }
                    )) {
                        ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle(isOn: Binding(
                        get: { project.settings?.shellEscape ?? false },
                        set: { on in Task { await project.setShellEscape(on) } }
                    )) {
                        Text("Shell Escape")
                        Text("Lets packages such as minted run programs. Only for projects you trust.")
                    }
                }
                if let path = project.openPath {
                    separator
                    header("Document")
                    row("Name", (path as NSString).lastPathComponent)
                    row("Folder", folder(of: path))
                    if let counts = project.counts {
                        row("Words", counts.words.formatted())
                        row("Lines", counts.lines.formatted())
                    }
                    if !project.outline.isEmpty {
                        row("Sections", project.outline.count.formatted())
                    }
                }
                separator
                header("Build")
                if let result = project.result {
                    row("Last Build", result.ok ? "Succeeded" : "Failed")
                    row("Duration", result.durationText)
                    row("Errors", project.errorCount.formatted())
                    row("Warnings", project.warningCount.formatted())
                } else {
                    // The status bar's phrase, shortened to fit beside its
                    // label in a narrow inspector.
                    row("Last Build", project.pdfVersion > 0 ? "None Yet" : "None")
                }
                if let freshness = project.pdfFreshness {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Label(freshness.title, systemImage: freshness.systemImage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(project.settings == nil)
            .monospacedDigit()
            .padding(BarMetrics.inset * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.headline).gridCellColumns(2)
    }

    private var separator: some View {
        Divider().gridCellColumns(2).padding(.vertical, BarMetrics.spacing)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            label(name)
            Text(value).textSelection(.enabled)
        }
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
