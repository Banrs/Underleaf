import SwiftUI
import WebKit

/// Hosts the app's one editor web view, and keeps its appearance in step with
/// the system and Settings.
struct EditorView: NSViewRepresentable {
    let bridge: EditorBridge
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 13

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

/// The editors: the source beside the PDF, a panel for the build that
/// shows and hides below them (as VS Code's does), and a status bar along
/// the foot.
struct EditorArea: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            editors
            // Stacked, not overlaid: an opaque bar over the editors only hid
            // their last lines.
            Divider()
            StatusBar(project: project)
        }
    }

    private var editors: some View {
        SplitController(app: app, axis: .vertical, autosave: "PanelSplit", panes: [
            SplitPane(minimum: 120) { SourceAndPDF(project: project) },
            SplitPane(minimum: 80, fraction: 0.3, keepsSize: true, shown: project.showLogs) {
                PanelView(project: project)
            },
        ])
    }
}

/// The source beside the PDF. A view of its own, as a split's pane is
/// made once and must observe the project itself.
private struct SourceAndPDF: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        SplitController(app: app, axis: .horizontal, autosave: "PDFSplit", panes: [
            SplitPane(minimum: 140) { SourcePane(project: project) },
            SplitPane(minimum: 140, fraction: 0.5, shown: project.showPDF) { PDFPane(project: project) },
        ])
    }
}

/// The source's bars stacked over it, not overlaid: they are opaque, so
/// text scrolled beneath them was only hidden.
private struct SourcePane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            SourceBar(project: project)
            SourceLocation(project: project)
            Divider()
            if project.openPath != nil {
                EditorView(bridge: app.editor)
            } else {
                // No file open, or it was deleted: nothing to type into
                // (workspace.js `showEditorPlaceholder`).
                ContentUnavailableView("No File Open", systemImage: "doc.text",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A pane of a `SplitController`: its view, its smallest (and largest)
/// size, the share of the split it opens at, whether it keeps its size as
/// the window resizes, and whether it shows.
struct SplitPane {
    var minimum: CGFloat
    var maximum: CGFloat?
    var fraction: CGFloat?
    var keepsSize = false
    var shown = true
    let content: AnyView

    init(minimum: CGFloat, maximum: CGFloat? = nil, fraction: CGFloat? = nil, keepsSize: Bool = false,
         shown: Bool = true, @ViewBuilder content: () -> some View) {
        self.minimum = minimum
        self.maximum = maximum
        self.fraction = fraction
        self.keepsSize = keepsSize
        self.shown = shown
        self.content = AnyView(content())
    }
}

/// AppKit's split view: its dividers and resize pointers, a pane that hides
/// collapsing with its divider, and divider positions remembered under
/// `autosave`.
///
/// Not SwiftUI's: HSplitView and VSplitView laid their panes out past their
/// bounds, and `.inspector` crashed the window on resize ("more Update
/// Constraints passes than views"). Not NSSplitViewController either: it
/// blurs the top of each pane under the toolbar, where the pane bars sit.
struct SplitController: NSViewRepresentable {
    let app: AppModel
    let axis: Axis
    let autosave: String
    let panes: [SplitPane]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = axis == .horizontal
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        context.coordinator.panes = panes
        let rest = 1 - panes.compactMap(\.fraction).reduce(0, +)
        for pane in panes {
            // Made once: the views observe the models themselves.
            let host = NSHostingView(rootView: AnyView(pane.content.environment(app)))
            // SwiftUI's sizes stay out of Auto Layout; the delegate keeps
            // each pane within its minimum and maximum instead.
            host.sizingOptions = []
            // Starting sizes in proportion, until the split has its own.
            let share = (pane.fraction ?? rest) * 1000
            host.frame.size = axis == .horizontal
                ? CGSize(width: share, height: 1000) : CGSize(width: 1000, height: share)
            context.coordinator.views.append(host)
            if pane.shown { split.addArrangedSubview(host) }
        }
        split.autosaveName = autosave
        return split
    }

    /// Shows and hides panes. A hidden pane leaves the split (AppKit kept
    /// room for a merely hidden one); coming back, it gets the size it had,
    /// or its share the first time.
    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.panes = panes
        for (index, (view, pane)) in zip(coordinator.views, panes).enumerated() where (view.superview === split) != pane.shown {
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            if pane.shown {
                let before = coordinator.views[..<index].filter { $0.superview === split }.count
                split.insertArrangedSubview(view, at: before)
                split.adjustSubviews()
                if before > 0 {
                    let size = coordinator.sizes[index] ?? (pane.fraction ?? 0.5) * total
                    split.setPosition(total - size - split.dividerThickness, ofDividerAt: before - 1)
                }
            } else {
                coordinator.sizes[index] = split.isVertical ? view.frame.width : view.frame.height
                split.removeArrangedSubview(view)
                view.removeFromSuperview()
                split.adjustSubviews()
            }
        }
    }

    /// The whole proposal: the split fills its place, and its panes'
    /// minimums don't reach the window's layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// Keeps a dragged divider where both panes beside it stay within
    /// their sizes.
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var panes: [SplitPane] = []
        var views: [NSView] = []
        /// The sizes of hidden panes, by index.
        var sizes: [Int: CGFloat] = [:]

        /// The pane shown at a place in the split.
        private func pane(_ split: NSSplitView, _ place: Int) -> SplitPane {
            panes[views.firstIndex(of: split.arrangedSubviews[place]) ?? place]
        }

        private func span(_ split: NSSplitView, _ place: Int) -> (CGFloat, CGFloat) {
            let frame = split.arrangedSubviews[place].frame
            return split.isVertical ? (frame.minX, frame.maxX) : (frame.minY, frame.maxY)
        }

        /// A pane that keeps its size leaves a window resize to the others.
        func splitView(_ split: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            guard let index = views.firstIndex(of: view) else { return true }
            return !panes[index].keepsSize
        }

        func splitView(_ split: NSSplitView, constrainMinCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            var low = span(split, place).0 + pane(split, place).minimum
            if let maximum = pane(split, place + 1).maximum { low = max(low, span(split, place + 1).1 - maximum) }
            return max(proposed, low)
        }

        func splitView(_ split: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            var high = span(split, place + 1).1 - pane(split, place + 1).minimum
            if let maximum = pane(split, place).maximum { high = min(high, span(split, place).0 + maximum) }
            return min(proposed, high)
        }
    }
}

/// The pane bars' two sizes (Settings › General › Toolbar Size): AppKit's
/// Large controls, or its Extra Large ones, the window toolbar's size.
enum PaneSize: String {
    case compact, large

    var controlSize: ControlSize { self == .large ? .extraLarge : .large }
    /// A control, with the standard toolbar's 8 pt above and below.
    var barHeight: CGFloat { self == .large ? 52 : 44 }
}

/// A pane's actions: the second row under the window toolbar, in native
/// controls of the size Settings chooses (`PaneSize`), spaced as the
/// standard toolbar spaces its items: 8 pt insets, 8 pt between groups.
struct PaneBar<Content: View>: View {
    @AppStorage("paneBarSize") private var size = PaneSize.compact
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) { content }
        }
        .controlSize(size.controlSize)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: size.barHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// A pane's location: the row under its actions, as Xcode's jump bar sits
/// under its tab bar, directly over the content.
struct LocationBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }
}

/// One action in a glass group.
struct Segment: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var help: String?
    var enabled = true
    let action: () -> Void
}

extension Segment {
    /// A menu command; its shortcut shows in the menu, not the tooltip.
    @MainActor
    init(_ command: MenuCommand, _ systemImage: String, app: AppModel) {
        self.init(id: command.rawValue, title: command.title, systemImage: systemImage,
                  enabled: app.isEnabled(command)) { app.perform(command) }
    }
}

/// A group of actions as one Liquid Glass capsule, as a window toolbar
/// groups its items: native glass buttons whose glass is merged into one
/// shape (`glassEffectUnion`), with no separators. The pane bar's
/// GlassEffectContainer does the merging.
struct GlassGroup: View {
    let items: [Segment]
    @Namespace private var group

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button(item.title, systemImage: item.systemImage, action: item.action)
                    .disabled(!item.enabled)
                    .help(item.help ?? item.title)
                    .glassEffectUnion(id: "group", namespace: group)
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}

/// The bar over the source: a writer's tools, not a programmer's — what
/// Overleaf's editor toolbar and the web's (workspace.js `editorToolbar`)
/// offer, at the leading edge as Xcode places its editor's controls:
/// history; the heading style; bold, italic and math; references and
/// citations; then inserting figures, tables and lists. Commenting out is a
/// code editor's tool; it stays in the Format menu (⌘/).
private struct SourceBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        PaneBar {
            // Narrow panes fold groups into the menus, as a toolbar overflows.
            ViewThatFits(in: .horizontal) {
                tools(folded: 0)
                tools(folded: 1)
                tools(folded: 2)
            }
            Spacer(minLength: 0)
        }
    }

    /// 0: everything; 1: references join Insert; 2: all but history in one
    /// Format menu.
    private func tools(folded: Int) -> some View {
        HStack(spacing: 8) {
            GlassGroup(items: [
                Segment(.editUndo, "arrow.uturn.backward", app: app),
                Segment(.editRedo, "arrow.uturn.forward", app: app),
            ])
            if isLaTeX {
                if folded < 2 {
                    templateMenu("Heading", headingTemplates)
                        .help("Heading")
                    GlassGroup(items: [
                        Segment(.editBold, "bold", app: app),
                        Segment(.editItalic, "italic", app: app),
                        Segment(.editMath, "x.squareroot", app: app),
                    ])
                }
                if folded == 0 {
                    GlassGroup(items: [
                        Segment(id: "ref", title: "Reference", systemImage: "number", help: "Reference (\\ref)") {
                            project.format("insert", "\\ref{$0}")
                        },
                        Segment(id: "cite", title: "Citation", systemImage: "text.quote", help: "Citation (\\cite)") {
                            project.format("insert", "\\cite{$0}")
                        },
                    ])
                }
                insertMenu(folded: folded)
            }
        }
        .fixedSize()
    }

    private func templateMenu(_ title: String, _ templates: [(String, String)]) -> some View {
        Menu(title) {
            ForEach(templates, id: \.0) { label, template in
                Button(label) { project.format("insert", template) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }

    /// Words, like Heading: a "+" here read as the sidebar's add-file button.
    private func insertMenu(folded: Int) -> some View {
        Menu(folded == 2 ? "Format" : "Insert") {
            if folded == 2 {
                ForEach([MenuCommand.editBold, .editItalic, .editMath], id: \.self) { command in
                    Button(command.title) { app.perform(command) }
                }
                Divider()
            }
            // What the bar isn't showing as controls of its own.
            InsertMenuItems(project: project, headings: folded == 2, references: folded >= 1)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .help(folded == 2 ? "Format" : "Insert")
    }

    private var isLaTeX: Bool { project.openPath?.hasSuffix(".tex") == true }
}

/// Where the cursor is, as Xcode's jump bar shows it: the project, its
/// folders, the file — a menu of the files beside it — and the section
/// around the cursor, a menu of the file's sections. Narrow panes drop the
/// project and folders first, then the section.
private struct SourceLocation: View {
    @Bindable var project: ProjectModel

    var body: some View {
        LocationBar {
            if let path = project.openPath {
                ViewThatFits(in: .horizontal) {
                    crumbs(path, folders: true, section: true)
                    crumbs(path, folders: false, section: true)
                    crumbs(path, folders: false, section: false)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func crumbs(_ path: String, folders: Bool, section: Bool) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            if folders {
                crumb(project.id, "folder")
                ForEach(Array(parts.dropLast().enumerated()), id: \.offset) { _, folder in
                    chevron
                    crumb(folder, "folder")
                }
                chevron
            }
            fileMenu(path, name: parts.last ?? path)
            if section, !project.outline.isEmpty {
                chevron
                sectionMenu
            }
        }
        .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
    }

    /// The file, a menu of the text files in its folder.
    private func fileMenu(_ path: String, name: String) -> some View {
        let folder = (path as NSString).deletingLastPathComponent
        let siblings = textFiles(project.tree).filter { ($0 as NSString).deletingLastPathComponent == folder }
        return Menu {
            ForEach(siblings, id: \.self) { file in
                Button((file as NSString).lastPathComponent) { Task { await project.open(file) } }
            }
        } label: {
            Label(name, systemImage: "doc.text").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help(path)
    }

    /// The section at the cursor, a menu of the file's sections.
    private var sectionMenu: some View {
        let chain = Outline.chain(project.outline, at: project.cursorLine)
        let depths = Outline.depths(project.outline)
        return Menu {
            ForEach(project.outline) { item in
                Button(String(repeating: "    ", count: depths[item.id]) + Outline.displayTitle(item)) {
                    if let path = project.openPath { Task { await project.open(path, line: item.line) } }
                }
            }
        } label: {
            Label(chain.last.map(Outline.displayTitle) ?? "Top of File", systemImage: "list.bullet.indent")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .foregroundStyle(chain.isEmpty ? .secondary : .primary)
        .help("Go to a Section")
    }

    private func textFiles(_ nodes: [TreeNode]) -> [String] {
        nodes.flatMap { node in
            node.isDirectory ? textFiles(node.children ?? []) : (isTextFile(node.path) ? [node.path] : [])
        }
    }
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

/// The status bar: how the build went (choose it for the panel's errors and
/// warnings), the save state and where the cursor is, then the panel's
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
            .help(project.showLogs ? "Hide Panel" : "Show Panel")
        }
        // The small system font (11 pt), as Finder's and Xcode's status bars.
        .font(.subheadline)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
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
                // A PDF from an earlier session is on screen but not this build.
                Text(project.pdfVersion > 0 ? "Ready" : "Not Compiled")
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
