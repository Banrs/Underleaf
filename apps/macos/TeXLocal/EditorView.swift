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
        .safeAreaBar(edge: .top) { SourceBar(project: project) }
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
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) { content }
        }
            .font(.callout)
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

/// Related controls sharing one wide Liquid Glass capsule, drawn as the
/// window toolbar draws a group: one surface that responds as a whole, its
/// buttons at toolbar size (38 x 30 pt) rather than squeezed together.
struct GlassPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(.borderless)
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
    }
}

/// A pill button's size.
let pillItem = CGSize(width: 38, height: 30)

/// One action in an editing pill.
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
    init(_ command: MenuCommand, _ systemImage: String, app: AppModel, enabled: Bool = true) {
        self.init(id: command.rawValue, title: command.title, systemImage: systemImage,
                  help: command.accel.map { "\(command.title) (\(chord($0)))" },
                  enabled: enabled && app.isEnabled(command)) { app.perform(command) }
    }

    /// Insert a LaTeX template ("$0" marks where the cursor lands).
    @MainActor
    init(_ title: String, _ systemImage: String, template: String, project: ProjectModel, enabled: Bool) {
        self.init(id: title, title: title, systemImage: systemImage, enabled: enabled) {
            project.format("insert", template)
        }
    }
}

/// A run of actions, in groups split by hairlines, that tracks the pointer
/// across them as Liquid Glass groups and segmented controls do: press,
/// slide to any action — the highlight glides under the pointer — and
/// release to choose it; release outside to cancel. Separate Buttons each
/// keep their own press, so a slide off one never reached its neighbour.
/// Drawn inside a GlassCapsule, beside any menus sharing it.
struct SegmentRun: View {
    let groups: [[Segment]]
    @State private var frames: [String: CGRect] = [:]
    @State private var pressed: String?
    @State private var hovered: String?
    @State private var pressing = false
    @Namespace private var lens
    private let space = UUID()

    var body: some View {
        HStack(spacing: 0) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 { PillSeparator() }
                ForEach(groups[index]) { cell($0) }
            }
        }
        .coordinateSpace(.named(space))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { drag in
                    pressing = true
                    pressed = item(at: drag.location)?.id
                }
                .onEnded { drag in
                    let chosen = item(at: drag.location)
                    pressing = false
                    pressed = nil
                    chosen?.action()
                }
        )
        .animation(.snappy(duration: 0.18), value: highlighted)
        .animation(.snappy(duration: 0.12), value: pressing)
    }

    private func cell(_ item: Segment) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(item.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: pillItem.width, height: pillItem.height)
            .background {
                if highlighted == item.id {
                    Capsule()
                        .fill(.primary.opacity(pressing ? 0.14 : 0.07))
                        .matchedGeometryEffect(id: "lens", in: lens)
                }
            }
            .contentShape(.rect)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames[item.id] = $0 }
            .help(item.help ?? item.title)
            .onHover { inside in
                if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if item.enabled { item.action() } }
    }

    /// Under the pointer while pressed; under it on hover otherwise.
    private var highlighted: String? {
        let id = pressing ? pressed : hovered
        return groups.joined().first { $0.id == id && $0.enabled }?.id
    }

    /// The enabled item at a point, with slack above and below, as a control
    /// keeps tracking just past its edge; a hairline's gap is neither.
    private func item(at point: CGPoint) -> Segment? {
        groups.joined().first { item in
            guard item.enabled, let frame = frames[item.id] else { return false }
            return frame.insetBy(dx: 0, dy: -12).contains(point)
        }
    }
}

/// One wide Liquid Glass capsule around runs, menus and hairlines.
struct GlassCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
    }
}

/// The hairline between groups in a pill.
struct PillSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }
}

/// An icon button sized for a GlassPill.
struct PillButton: View {
    let title: String
    let systemImage: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: pillItem.width, height: pillItem.height)
                .contentShape(.rect)
        }
        .help(help ?? title)
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
/// offer, at the leading edge as Xcode places its editor's controls. History; the heading style; bold and italic; math; the two
/// things a paper points at, references and citations; then inserting
/// figures, tables and lists. Commenting out is a code editor's tool; it
/// stays in the Format menu (⌘/). Where the cursor is shows in the window's
/// title and the sidebar's outline, so the bar carries no breadcrumb.
/// Groups are separate pills, without hairlines, as Xcode's toolbar has them.
private struct SourceBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        PaneBar {
            // Narrow panes fold groups into the menus, as a toolbar overflows.
            ViewThatFits(in: .horizontal) {
                pill(folded: 0)
                pill(folded: 1)
                pill(folded: 2)
            }
            Spacer(minLength: 0)
        }
    }

    /// 0: everything; 1: references join Insert; 2: all but history in one
    /// Format menu. Each group is its own pill, as a toolbar groups related
    /// items: history, the heading style, text (bold, italic, math), what a
    /// paper points at (references, citations), and inserting.
    private func pill(folded: Int) -> some View {
        HStack(spacing: 8) {
            GlassCapsule {
                SegmentRun(groups: [[
                    Segment(.editUndo, "arrow.uturn.backward", app: app),
                    Segment(.editRedo, "arrow.uturn.forward", app: app),
                ]])
            }
            if isLaTeX {
                if folded < 2 {
                    GlassCapsule { headingMenu }
                    GlassCapsule {
                        SegmentRun(groups: [[
                            Segment(.editBold, "bold", app: app),
                            Segment(.editItalic, "italic", app: app),
                            Segment(.editMath, "x.squareroot", app: app),
                        ]])
                    }
                }
                if folded == 0 {
                    GlassCapsule {
                        SegmentRun(groups: [[
                            Segment("Reference", "number", template: "\\ref{$0}", project: project, enabled: true),
                            Segment("Citation", "text.quote", template: "\\cite{$0}", project: project, enabled: true),
                        ]])
                    }
                }
                GlassCapsule { insertMenu(folded: folded) }
            }
        }
        .fixedSize()
    }

    /// Pages' paragraph-style menu, for LaTeX's sectioning.
    private var headingMenu: some View {
        Menu {
            ForEach(headingTemplates, id: \.0) { label, template in
                Button(label) { project.format("insert", template) }
            }
        } label: {
            Text("Heading")
                .padding(.leading, 10)
                .frame(height: pillItem.height)
                .contentShape(.rect)
        }
        // The system's indicator, trailing the title as a pop-up's does.
        .menuIndicator(.visible)
        .padding(.trailing, 8)
        .help("Insert a part, chapter, section or subsection")
    }

    private func insertMenu(folded: Int) -> some View {
        Menu {
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
        } label: {
            Label(folded == 2 ? "Format" : "Insert", systemImage: folded == 2 ? "textformat" : "plus")
                .labelStyle(.iconOnly)
                .frame(width: pillItem.width, height: pillItem.height)
                .contentShape(.rect)
        }
        .help(folded == 2 ? "Format and insert" : "Insert a figure, table, equation or list")
    }

    private var isLaTeX: Bool { project.openPath?.hasSuffix(".tex") == true }
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
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
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
