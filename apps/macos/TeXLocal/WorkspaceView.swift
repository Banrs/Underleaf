import SwiftUI

/// An open project: files and outline in the sidebar; the source beside its
/// PDF, with a panel for the build below; and an inspector on the trailing
/// edge.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var promptText = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            NavigatorView(project: project)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            SplitController(app: app, axis: .horizontal, autosave: "InspectorSplit", panes: [
                SplitPane(minimum: 441) { EditorArea(project: project) },
                SplitPane(minimum: 220, maximum: 320, fraction: 0.28, keepsSize: true,
                          shown: app.showInspector) {
                    InspectorView(project: project)
                },
            ])
            // Built once per project: its panes keep the views they were made with.
            .id(ObjectIdentifier(project))
            .frame(minWidth: 441, minHeight: 280)
            // On the detail, as Apple's Landmarks sample has it: on the split
            // view itself the spacers were dropped and every item ran
            // together in one pill.
            .toolbar { toolbar }
        }
        .navigationTitle(project.openPath.map { ($0 as NSString).lastPathComponent } ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        .navigationDocument(project.openURL ?? URL(fileURLWithPath: "/"))
        .alert(promptTitle, isPresented: Binding(
            get: { app.prompt != nil }, set: { if !$0 { app.prompt = nil } }
        ), presenting: app.prompt) { prompt in
            TextField(promptLabel(prompt), text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(promptAction(prompt)) { submit(prompt) }
                .disabled(!isValid(prompt))
        }
        .onChange(of: app.prompt?.id) { _, _ in promptText = promptDefault }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // This window's only: closing Settings is no reason to save.
            guard (note.object as? NSWindow) === app.editor.webView.window else { return }
            Task { await project.flush() }
        }
    }

    // ---------- toolbar ----------

    /// Back and the file as the window's title at the leading edge, and the panes'
    /// toggles at the trailing. What acts on a pane sits over it instead:
    /// editing over the source (EditorView's `SourceBar`), compiling and
    /// sharing over the PDF (PDFPane's bar). Every item is in the menu bar
    /// too.
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

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $project.showPDF) {
                Label("PDF", systemImage: "doc.richtext")
            }
            .help(project.showPDF ? "Hide PDF" : "Show PDF")
            Toggle(isOn: Bindable(app).showInspector) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(app.showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    // ---------- prompts ----------

    private var promptTitle: String {
        switch app.prompt {
        case .newFile: "New File"
        case .newFolder: "New Folder"
        case .gotoLine: "Go to Line"
        case .renameEntry(let path): "Rename “\((path as NSString).lastPathComponent)”"
        case .renameProject: "Rename Project"
        case nil: ""
        }
    }

    private var promptDefault: String {
        switch app.prompt {
        case .renameEntry(let path): path
        case .renameProject(let p): p.name
        default: ""
        }
    }

    private func promptLabel(_ prompt: Prompt) -> String {
        switch prompt {
        case .newFile: "Path, e.g. sections/intro.tex"
        case .newFolder: "Path, e.g. figures"
        case .gotoLine: "Line number"
        case .renameEntry: "Path"
        case .renameProject: "Name"
        }
    }

    private func promptAction(_ prompt: Prompt) -> String {
        switch prompt {
        case .newFile, .newFolder: "Create"
        case .gotoLine: "Go"
        case .renameEntry, .renameProject: "Rename"
        }
    }

    private func isValid(_ prompt: Prompt) -> Bool {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        if case .gotoLine = prompt { return Int(text) != nil }
        return !text.isEmpty
    }

    private func submit(_ prompt: Prompt) {
        guard isValid(prompt) else { return }
        let text = promptText.trimmingCharacters(in: .whitespaces)
        Task {
            switch prompt {
            case .newFile: await project.createEntry(text, directory: false)
            case .newFolder: await project.createEntry(text, directory: true)
            case .gotoLine: if let line = Int(text) { project.reveal(line: line) }
            case .renameEntry(let from): await project.renameEntry(from, to: text)
            case .renameProject(let p): await app.rename(p, to: text)
            }
        }
    }
}

/// What LaTeX's Insert menu offers, in the source bar and the Format menu:
/// the web editor bar's heading, reference, list and insert menus
/// (workspace.js `editorToolbar`). The source bar leaves out headings and
/// references while it shows them as controls of their own.
struct InsertMenuItems: View {
    let project: ProjectModel?
    var headings = true
    var references = true

    var body: some View {
        if headings { submenu("Heading", headingTemplates) }
        if references { submenu("Reference", referenceTemplates) }
        if headings || references { Divider() }
        ForEach(insertTemplates.filter { !$0.0.hasSuffix("List") }, id: \.0) { label, template in
            Button(label) { project?.format("insert", template) }
        }
        submenu("List", listTemplates)
    }

    private func submenu(_ title: String, _ templates: [(String, String)]) -> some View {
        Menu(title) {
            ForEach(templates, id: \.0) { label, template in
                Button(label) { project?.format("insert", template) }
            }
        }
    }
}

/// The engines a project can compile with, for the compile menu and Settings.
let texEngines = [("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX")]

/// web/src/workspace.js `INSERT_TEMPLATES`; "$0" marks where the cursor lands.
let insertTemplates: [(String, String)] = [
    ("Figure", "\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n"),
    ("Table", "\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n"),
    ("Equation", "\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n"),
    ("Align (multi-line math)", "\\begin{align}\n  $0 \\\\\n\\end{align}\n"),
    ("Bulleted List", "\\begin{itemize}\n  \\item $0\n\\end{itemize}\n"),
    ("Numbered List", "\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n"),
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
                    Text("Lets packages such as minted run programs. Turn on only for projects you trust.")
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
                        Text("\(Double(result.durationMs) / 1000, format: .number.precision(.fractionLength(1))) s")
                            .monospacedDigit()
                    }
                    LabeledContent("Errors", value: project.errorCount.formatted())
                    LabeledContent("Warnings", value: project.warningCount.formatted())
                } else {
                    LabeledContent("Last Build", value: "Not compiled")
                }
                if let freshness = project.pdfFreshness {
                    Label(freshness.title, systemImage: freshness.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
