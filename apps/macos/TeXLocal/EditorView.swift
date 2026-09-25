import SwiftUI
import WebKit

/// Hosts the app's one editor web view, and keeps its appearance in step with
/// the system and Settings.
struct EditorView: NSViewRepresentable {
    let bridge: EditorBridge
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 14

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
        let (theme, palette, font, fontSize) = (colorScheme == .dark ? "dark" : "light", palette, font, fontSize)
        Task { await bridge.setAppearance(theme: theme, palette: palette, font: font, fontSize: fontSize) }
    }

    /// The web view outlives any one container (it moves between projects),
    /// so it is re-parented rather than recreated.
    private func attach(to container: NSView) {
        let web = bridge.webView
        guard web.superview !== container else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// ---------- the editor area ----------

/// The detail column: the source beside the PDF, a panel for the build that
/// shows and hides below them (as VS Code's does), and a status bar along
/// the foot.
///
/// Split in SwiftUI rather than with HSplitView/VSplitView: those host each
/// pane in its own AppKit view whose size feeds Auto Layout, and inside the
/// sidebar's and inspector's split views that looped — the window grew when
/// the inspector opened, stalled, and at worst threw "more Update
/// Constraints passes than views". Here the area asks only for a small
/// minimum, so revealing either sidebar takes its width from the editors,
/// as Xcode's does, and the window grows only once they are at their minimum.
struct EditorArea: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @AppStorage("pdfSplit") private var pdfSplit = 0.5
    @AppStorage("panelSplit") private var panelSplit = 0.7

    var body: some View {
        SplitPair(axis: .vertical, fraction: $panelSplit, minFirst: 180, minSecond: 90,
                  showsSecond: project.showLogs) {
            SplitPair(axis: .horizontal, fraction: $pdfSplit, minFirst: 220, minSecond: 220,
                      showsSecond: project.showPDF) {
                source
            } second: {
                PDFPane(project: project)
            }
        } second: {
            PanelView(project: project)
        }
        .safeAreaBar(edge: .bottom) { StatusBar(project: project) }
    }

    @ViewBuilder
    private var source: some View {
        Group {
            if project.openPath != nil {
                EditorView(bridge: app.editor)
                    .safeAreaBar(edge: .top) {
                        if project.openPath?.hasSuffix(".tex") == true { FormatBar(project: project) }
                    }
            } else {
                // No file open, or it was deleted: nothing to type into
                // (workspace.js `showEditorPlaceholder`).
                ContentUnavailableView("No File Open", systemImage: "doc.text",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaBar(edge: .top) { JumpBar(project: project) }
    }
}

/// Two panes and a divider to drag between them. The first keeps its place
/// in the view tree when the second hides, so the editor is never rebuilt.
struct SplitPair<First: View, Second: View>: View {
    let axis: Axis
    @Binding var fraction: Double
    let minFirst: CGFloat
    let minSecond: CGFloat
    let showsSecond: Bool
    @ViewBuilder var first: First
    @ViewBuilder var second: Second
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let lead = showsSecond ? length(of: total) : total
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: axis == .horizontal ? lead : nil, height: axis == .vertical ? lead : nil)
                if showsSecond {
                    divider(total: total)
                    second.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The first pane's length: its share, kept within both minimums.
    private func length(of total: CGFloat) -> CGFloat {
        // Short of room for both minimums, the panes share it by the split's
        // proportion; neither goes below zero (a negative frame overflows the
        // reader and keeps layout re-measuring).
        let room = max(0, total - 1)
        if room < minFirst + minSecond { return (room * fraction).rounded() }
        return min(max(total * fraction, minFirst), room - minSecond).rounded()
    }

    /// The fractions the minimums allow, so a drag past one doesn't leave
    /// the divider stuck until the pointer comes back.
    private func clamp(_ value: Double, total: CGFloat) -> Double {
        let low = Double(minFirst / total), high = Double((total - minSecond - 1) / total)
        return low <= high ? min(max(value, low), high) : min(max(value, 0.05), 0.95)
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .overlay {
                // A wider grip than the line, as NSSplitView's thin divider has.
                Color.clear
                    .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                    .contentShape(.rect)
                    .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                guard total > 0 else { return }
                                let start = dragStart ?? fraction
                                dragStart = start
                                let delta = axis == .horizontal ? drag.translation.width : drag.translation.height
                                fraction = clamp(start + delta / total, total: total)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .accessibilityHidden(true)
            }
            .zIndex(1)
    }
}

/// A pane's header: one line of controls across the top of an editor or
/// the PDF, Xcode's jump-bar height, over the standard bar material.
struct PaneBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// Xcode's jump bar: the files at hand, then where the cursor is — project,
/// folders, file, and the sections that enclose it — each a menu to move
/// sideways.
private struct JumpBar: View {
    @Bindable var project: ProjectModel

    var body: some View {
        PaneBar {
            Menu {
                ForEach(textFiles(project.tree), id: \.self) { path in
                    Button(path) { Task { await project.open( path) } }
                }
            } label: {
                Label("Project Files", systemImage: "square.grid.2x2")
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Open a File in the Project")
            Divider().frame(height: 16)
            crumb(project.id, systemImage: "folder")
            if let path = project.openPath {
                let parts = path.split(separator: "/").map(String.init)
                ForEach(parts.dropLast(), id: \.self) { folder in
                    separator
                    crumb(folder, systemImage: "folder")
                }
                separator
                crumb(parts.last ?? path, systemImage: "doc.text")
                    .layoutPriority(2)
                separator
                sectionMenu
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
    }

    /// The section at the cursor, a menu of the file's sections.
    private var sectionMenu: some View {
        let chain = Outline.chain(project.outline, at: project.cursorLine)
        return Menu(chain.last?.title ?? "No Selection") {
            ForEach(project.outline) { item in
                Button(String(repeating: "   ", count: max(0, item.level - 2)) + item.title) {
                    if let path = project.openPath { Task { await project.open( path, line: item.line) } }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(project.outline.isEmpty)
    }

    private func textFiles(_ nodes: [TreeNode]) -> [String] {
        nodes.flatMap { node in
            node.isDirectory ? textFiles(node.children ?? []) : (isTextFile(node.path) ? [node.path] : [])
        }
    }
}

/// Xcode's formatting bar for rich text, here for LaTeX: glass pills at the
/// top trailing corner of the source, carrying what the web's editor bar
/// did (workspace.js `editorToolbar`) — history, headings, emphasis and
/// math, references, lists, inserting environments, commenting, finding.
private struct FormatBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        // Narrow panes fold the menus, then everything but history, into
        // one menu rather than clip them (a window can be 800 pt wide).
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                bar {
                    history
                    pill { templateMenu("Heading", systemImage: nil, headingTemplates) }
                    emphasis
                    pill { templateMenu("References", systemImage: "link", referenceTemplates) }
                    pill { templateMenu("Lists", systemImage: "list.bullet", listTemplates) }
                    pill { templateMenu("Insert", systemImage: "plus", insertItems) }
                    tools
                }
                bar {
                    history
                    emphasis
                    pill { everything(systemImage: "plus") }
                    tools
                }
                bar {
                    history
                    pill { everything(systemImage: "ellipsis") }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content()
        }
    }

    private var history: some View {
        pill {
            command(.editUndo, "arrow.uturn.backward")
            command(.editRedo, "arrow.uturn.forward")
        }
    }

    private var emphasis: some View {
        pill {
            command(.editBold, "bold")
            command(.editItalic, "italic")
            command(.editMath, "function")
        }
    }

    private var tools: some View {
        pill {
            command(.editComment, "percent")
            command(.editFind, "magnifyingglass")
        }
    }

    private var insertItems: [(String, String)] { insertTemplates.filter { !$0.0.hasSuffix("List") } }

    /// Every inserting menu as submenus of one, with the commands when the
    /// pills that hold them are folded too.
    private func everything(systemImage: String) -> some View {
        Menu {
            if systemImage == "ellipsis" {
                ForEach([MenuCommand.editBold, .editItalic, .editMath, .editComment, .editFind], id: \.self) { command in
                    Button(command.title) { app.perform(command) }.disabled(!app.isEnabled(command))
                }
                Divider()
            }
            submenu("Heading", headingTemplates)
            submenu("References", referenceTemplates)
            submenu("Lists", listTemplates)
            submenu("Insert", insertItems)
        } label: {
            Label("Insert", systemImage: systemImage).labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .fixedSize()
        .padding(.horizontal, 4)
        .help("Insert")
    }

    private func submenu(_ title: String, _ templates: [(String, String)]) -> some View {
        Menu(title) {
            ForEach(templates, id: \.0) { label, template in
                Button(label) { project.format("insert", template) }
            }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func command(_ command: MenuCommand, _ systemImage: String) -> some View {
        Button { app.perform(command) } label: {
            Label(command.title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .disabled(!app.isEnabled(command))
        .help(command.accel.map { "\(command.title) (\(chord($0)))" } ?? command.title)
    }

    private func templateMenu(_ title: String, systemImage: String?, _ templates: [(String, String)]) -> some View {
        Menu {
            ForEach(templates, id: \.0) { label, template in
                Button(label) { project.format("insert", template) }
            }
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            } else {
                Text(title)
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .padding(.horizontal, 4)
        .help(title)
    }
}

/// "CmdOrCtrl+Shift+Z" as the menu shows it: ⇧⌘Z.
func chord(_ accel: String) -> String {
    var parts = accel.split(separator: "+").map(String.init)
    let key = parts.popLast() ?? ""
    let symbols: [String: String] = ["Ctrl": "⌃", "Alt": "⌥", "Shift": "⇧", "CmdOrCtrl": "⌘", "Cmd": "⌘"]
    let names: [String: String] = ["Return": "↩", "Plus": "+", "Minus": "−"]
    let order = ["Ctrl", "Alt", "Shift", "CmdOrCtrl", "Cmd"]
    return order.filter(parts.contains).compactMap { symbols[$0] }.joined() + (names[key] ?? key.uppercased())
}

/// The sectioning commands, in the order the web's outline ranks them.
let headingTemplates: [(String, String)] = [
    ("Part", "\\part{$0}\n"), ("Chapter", "\\chapter{$0}\n"), ("Section", "\\section{$0}\n"),
    ("Subsection", "\\subsection{$0}\n"), ("Subsubsection", "\\subsubsection{$0}\n"), ("Paragraph", "\\paragraph{$0} "),
]

/// Cross-references, citations and links; each opens completion inside
/// its braces.
let referenceTemplates: [(String, String)] = [
    ("Reference", "\\ref{$0}"), ("Equation Reference", "\\eqref{$0}"), ("Citation", "\\cite{$0}"),
    ("Label", "\\label{$0}"), ("Link", "\\href{$0}{}"), ("URL", "\\url{$0}"),
]

let listTemplates: [(String, String)] = [
    ("Bulleted List", "\\begin{itemize}\n  \\item $0\n\\end{itemize}\n"),
    ("Numbered List", "\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n"),
    ("Description List", "\\begin{description}\n  \\item[$0] \n\\end{description}\n"),
]

/// The status bar: how the build went (choose it for the panel's Issues), the save state and where the cursor is, then the panel's
/// toggle at the trailing end.
private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @AppStorage("showWordCount") private var showWordCount = true

    var body: some View {
        HStack(spacing: 12) {
            Button {
                project.panelTab = .issues
                project.showLogs = true
            } label: {
                buildStatus
            }
            .buttonStyle(.borderless)
            .help("Show Issues")
            .layoutPriority(1)
            Text(project.status)
            Spacer(minLength: 12)
            if project.openPath != nil {
                Text("Line \(project.cursorLine)").monospacedDigit()
                if showWordCount, let counts = project.counts {
                    Text("\(counts.words, format: .number) words · \(counts.lines, format: .number) lines")
                        .monospacedDigit()
                }
            }
            if let engine = project.settings?.engine {
                Text(texEngines.first { $0.0 == engine }?.1 ?? engine)
            }
            Divider().frame(height: 16)
            Toggle(isOn: $project.showLogs) {
                Label("Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help(project.showLogs ? "Hide Panel (⇧⌘L)" : "Show Panel (⇧⌘L)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var buildStatus: some View {
        HStack(spacing: 6) {
            if project.compiling {
                ProgressView().controlSize(.small)
                Text("Compiling…")
            } else if let result = project.result {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                Text(result.ok
                     ? "Compiled in \(Double(result.durationMs) / 1000, format: .number.precision(.fractionLength(1))) s"
                     : "Build Failed")
            } else {
                Text("Not Compiled")
            }
            if project.errorCount > 0 {
                Label("\(project.errorCount)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if project.warningCount > 0 {
                Label("\(project.warningCount)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .fixedSize()
    }
}
