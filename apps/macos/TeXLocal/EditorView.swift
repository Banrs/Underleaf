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
        SplitPair(axis: .vertical, fraction: $panelSplit, minFirst: 120, minSecond: 80,
                  showsSecond: project.showLogs) {
            SplitPair(axis: .horizontal, fraction: $pdfSplit, minFirst: 140, minSecond: 140,
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
            } else {
                // No file open, or it was deleted: nothing to type into
                // (workspace.js `showEditorPlaceholder`).
                ContentUnavailableView("No File Open", systemImage: "doc.text",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                SourceBar(project: project)
                SourceLocation(project: project)
            }
        }
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

    /// NSSplitView's cursor: two-way, or one-way once a pane is at its
    /// minimum and the divider can only move the other way.
    private func pointer(total: CGFloat) -> PointerStyle {
        let lead = length(of: total)
        let atFirstMin = lead <= minFirst + 0.5
        let atSecondMin = lead >= total - minSecond - 1.5
        if axis == .horizontal {
            let directions: HorizontalDirection.Set =
                atFirstMin && !atSecondMin ? .trailing : atSecondMin && !atFirstMin ? .leading : [.leading, .trailing]
            return .columnResize(directions: directions)
        } else {
            let directions: VerticalDirection.Set =
                atFirstMin && !atSecondMin ? .down : atSecondMin && !atFirstMin ? .up : [.up, .down]
            return .rowResize(directions: directions)
        }
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
                    .pointerStyle(pointer(total: total))
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

/// A pane's actions: the second row under the window toolbar. The macOS 27
/// UI kit's standard (Unified) toolbar spacing — 8 pt insets, 8 pt between
/// groups — with controls at the size of that toolbar's group buttons
/// (28 pt, Large), so the row is roomier than the kit's compact toolbar yet
/// still under the window toolbar's 36 pt.
struct PaneBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) { content }
        }
        .controlSize(.large)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.bar)
        // A shape, not Divider(): inside the HStack's layout context an
        // overlaid Divider turned vertical, a stray line down the middle.
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// A pane's location: the row under its actions, as Xcode's jump bar sits
/// under its tab bar, directly over the content.
struct LocationBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Hairline() }
    }
}

/// A group's capsule, 28 pt tall (Large), laid out as the kit lays out a
/// toolbar button group, scaled from its 36 pt: 3 pt inside the capsule,
/// 22 pt buttons, 7 pt between them (the kit: 4, 28 and 9).
let glassHeight: CGFloat = 28
let glassItem: CGFloat = 22
let glassPadding: CGFloat = 3
let glassGap: CGFloat = 7

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
    /// A menu command, with its shortcut in the tooltip.
    @MainActor
    init(_ command: MenuCommand, _ systemImage: String, app: AppModel) {
        self.init(id: command.rawValue, title: command.title, systemImage: systemImage,
                  help: command.accel.map { "\(command.title) (\(chord($0)))" },
                  enabled: app.isEnabled(command)) { app.perform(command) }
    }
}

/// A toolbar button group in Liquid Glass, as the kit draws one: one glass
/// capsule; a hairline only where the group mixes kinds (bold and italic |
/// math), as the kit's segmented control separates its segments. Press,
/// slide to another button — the highlight follows — and release to choose
/// it; release outside to cancel. The tracking is AppKit's
/// (`SegmentTracker`), so a slide reaches every button whatever SwiftUI's
/// gestures and the glass are doing.
struct GlassGroup: View {
    let groups: [[Segment]]
    @State private var pressed: String?
    @State private var hovered: String?
    @State private var pressing = false
    @Namespace private var lens

    init(items: [Segment]) { groups = [items] }
    init(groups: [[Segment]]) { self.groups = groups }

    private var items: [Segment] { Array(groups.joined()) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, glassGap / 2)
                }
                HStack(spacing: glassGap) {
                    ForEach(groups[index]) { cell($0) }
                }
            }
        }
        .padding(.horizontal, glassPadding)
        .overlay {
            SegmentTracker(
                count: items.count,
                enabled: items.map(\.enabled),
                help: items.map { $0.help ?? $0.title },
                onHover: { hovered = $0.map { items[$0].id } },
                onTrack: { index in pressing = true; pressed = index.map { items[$0].id } },
                onRelease: { index in
                    pressing = false
                    pressed = nil
                    if let index { items[index].action() }
                }
            )
            .accessibilityHidden(true)
        }
        .frame(height: glassHeight)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy(duration: 0.18), value: highlighted)
        .animation(.snappy(duration: 0.12), value: pressing)
        .fixedSize()
    }

    private func cell(_ item: Segment) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(item.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: glassItem, height: glassItem)
            .background {
                if highlighted == item.id {
                    Circle()
                        .fill(.primary.opacity(pressing ? 0.16 : 0.08))
                        .matchedGeometryEffect(id: "lens", in: lens)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if item.enabled { item.action() } }
    }

    /// Under the pointer while pressed; under it on hover otherwise.
    private var highlighted: String? {
        let id = pressing ? pressed : hovered
        return items.first { $0.id == id && $0.enabled }?.id
    }
}

/// The mouse for a GlassGroup: an AppKit view over it that maps the pointer
/// to a button (equal widths) on hover, through a press, and at release.
/// The view that takes the mouse-down gets every drag and the mouse-up, as
/// NSSegmentedControl tracks.
private struct SegmentTracker: NSViewRepresentable {
    let count: Int
    let enabled: [Bool]
    let help: [String]
    let onHover: (Int?) -> Void
    let onTrack: (Int?) -> Void
    let onRelease: (Int?) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.count = count
        view.enabled = enabled
        view.help = help
        view.onHover = onHover
        view.onTrack = onTrack
        view.onRelease = onRelease
    }

    final class TrackerView: NSView {
        var count = 0
        var enabled: [Bool] = []
        var help: [String] = []
        var onHover: (Int?) -> Void = { _ in }
        var onTrack: (Int?) -> Void = { _ in }
        var onRelease: (Int?) -> Void = { _ in }
        private var hovered: Int?

        // A toolbar's controls answer the first click in an inactive window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self
            ))
        }

        /// The enabled button under an event, with slack above and below as
        /// a control keeps tracking just past its edge.
        private func index(_ event: NSEvent) -> Int? {
            let point = convert(event.locationInWindow, from: nil)
            guard count > 0, bounds.width > 0, point.x >= 0, point.x < bounds.width,
                  point.y > -12, point.y < bounds.height + 12 else { return nil }
            let index = min(count - 1, Int(point.x / (bounds.width / CGFloat(count))))
            return enabled.indices.contains(index) && enabled[index] ? index : nil
        }

        private func hover(_ index: Int?) {
            guard index != hovered else { return }
            hovered = index
            toolTip = index.map { help[$0] }
            onHover(index)
        }

        override func mouseMoved(with event: NSEvent) { hover(index(event)) }
        override func mouseEntered(with event: NSEvent) { hover(index(event)) }
        override func mouseExited(with event: NSEvent) { hover(nil) }
        override func mouseDown(with event: NSEvent) { onTrack(index(event)) }
        override func mouseDragged(with event: NSEvent) { onTrack(index(event)) }
        override func mouseUp(with event: NSEvent) {
            let index = index(event)
            onRelease(index)
            hover(index)
        }
    }
}

/// A one-point separator line across the full width.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(.separator).frame(height: 1).frame(maxWidth: .infinity)
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
                        .help("Insert a part, chapter, section or subsection")
                    GlassGroup(groups: [
                        [Segment(.editBold, "bold", app: app), Segment(.editItalic, "italic", app: app)],
                        [Segment(.editMath, "x.squareroot", app: app)],
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
                Menu("Heading") {
                    ForEach(headingTemplates, id: \.0) { label, template in
                        Button(label) { project.format("insert", template) }
                    }
                }
            }
            if folded >= 1 {
                Menu("Reference") {
                    ForEach(referenceTemplates, id: \.0) { label, template in
                        Button(label) { project.format("insert", template) }
                    }
                }
            }
            Divider()
            ForEach(insertTemplates.filter { !$0.0.hasSuffix("List") }, id: \.0) { label, template in
                Button(label) { project.format("insert", template) }
            }
            Menu("List") {
                ForEach(listTemplates, id: \.0) { label, template in
                    Button(label) { project.format("insert", template) }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .help(folded == 2 ? "Format and insert" : "Insert a figure, table, equation or list")
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
            .help(project.showLogs ? "Hide Panel (⇧⌘L)" : "Show Panel (⇧⌘L)")
        }
        // The small system font (11 pt), as Finder's and Xcode's status bars.
        .font(.subheadline)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
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
