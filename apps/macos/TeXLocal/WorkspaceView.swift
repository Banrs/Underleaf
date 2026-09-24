import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var promptText = ""
    @AppStorage("showWordCount") private var showWordCount = true

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView(project: project)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            HSplitView {
                Group {
                    if project.openPath != nil {
                        EditorView(bridge: app.editor)
                            .overlay(alignment: .bottomTrailing) { wordCount }
                    } else {
                        // No file open, or it was deleted: nothing to type
                        // into (workspace.js `showEditorPlaceholder`).
                        ContentUnavailableView("Select a File to Edit", systemImage: "doc.text")
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if project.showPDF || project.showLogs {
                    Group {
                        if project.showLogs {
                            LogsView(project: project)
                        } else {
                            PDFPane(project: project)
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(project.id)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .alert(promptTitle, isPresented: Binding(
            get: { app.prompt != nil }, set: { if !$0 { app.prompt = nil } }
        ), presenting: app.prompt) { prompt in
            TextField(promptLabel(prompt), text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(promptAction(prompt)) { submit(prompt) }
        }
        .onChange(of: app.prompt?.id) { _, _ in promptText = promptDefault }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // This window's only: closing Settings is no reason to save.
            guard (note.object as? NSWindow) === app.editor.webView.window else { return }
            Task { await project.flush() }
        }
    }

    /// The breadcrumb, then the save state.
    private var subtitle: String {
        let crumbs = project.breadcrumb.joined(separator: " › ")
        return crumbs.isEmpty ? project.status : "\(crumbs) — \(project.status)"
    }

    /// Words and lines in the open .tex file, in the editor's corner like the
    /// web's pill (workspace.js `updateDocMeta`).
    @ViewBuilder
    private var wordCount: some View {
        if showWordCount, let counts = project.counts {
            Text("\(counts.words, format: .number) words · \(counts.lines, format: .number) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .glassEffect()
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
    }

    // ---------- toolbar ----------

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Projects", systemImage: "chevron.backward") { app.perform(.projectClose) }
                .help("Close Project")
        }
        ToolbarItemGroup {
            Menu("Insert", systemImage: "plus") {
                ForEach(insertTemplates, id: \.0) { label, template in
                    Button(label) { project.format("insert", template) }
                }
            }
            .help("Insert an environment")
            ControlGroup {
                Button("Bold", systemImage: "bold") { app.perform(.editBold) }
                Button("Italic", systemImage: "italic") { app.perform(.editItalic) }
                Button("Inline Math", systemImage: "function") { app.perform(.editMath) }
            }
        }
        ToolbarItem {
            Spacer()
        }
        ToolbarItemGroup {
            compileButton
            Button {
                app.perform(.viewToggleLogs)
            } label: {
                Label("Compile Log", systemImage: "list.bullet.rectangle")
            }
            .badge(project.errorCount)
            .help(logHelp)
            Toggle(isOn: $project.showPDF) {
                Label("PDF", systemImage: "sidebar.right")
            }
            .help("Show or hide the PDF")
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button(MenuCommand.pdfSave.title) { app.perform(.pdfSave) }
                    .disabled(!app.isEnabled(.pdfSave))
                Button(MenuCommand.projectExport.title) { app.perform(.projectExport) }
            }
        }
    }

    /// Compile is the primary action; the engine and auto-compile live in its
    /// menu, the way a split button carries a default and its options.
    private var compileButton: some View {
        Menu {
            Picker("Engine", selection: Binding(
                get: { project.settings?.engine ?? "pdflatex" },
                set: { engine in Task { await project.setEngine(engine) } }
            )) {
                ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            Toggle(MenuCommand.compileToggleAuto.title, isOn: Bindable(app).autoCompile)
        } label: {
            if project.compiling {
                ProgressView().controlSize(.small)
            } else {
                Label("Compile", systemImage: "play.fill")
            }
        } primaryAction: {
            app.perform(.compileRun)
        }
        .disabled(!project.texAvailable)
        .help(project.texAvailable ? "Compile (⌘↩)" : "Install TeX to compile")
    }

    private var logHelp: String {
        switch (project.errorCount, project.warningCount) {
        case (0, 0): "Compile Log"
        case (let e, let w): "Compile Log — \(e) errors, \(w) warnings"
        }
    }

    // ---------- prompts ----------

    private var promptTitle: String {
        switch app.prompt {
        case .newFile: "New File"
        case .newFolder: "New Folder"
        case .gotoLine: "Go to Line"
        case .renameEntry: "Rename"
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

    private func submit(_ prompt: Prompt) {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
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
