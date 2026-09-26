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

    /// The whole proposal, as the split's panes. Otherwise SwiftUI measures
    /// the container through Auto Layout, updating its constraints inside
    /// the window's constraint pass: the path of the 25 Sep crashes ("more
    /// Update Constraints in Window passes than there are views").
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// The web view outlives any one container (it moves between projects),
    /// so it is re-parented rather than recreated. It follows the container
    /// by its autoresizing mask: constraints added here would land in
    /// whatever layout pass SwiftUI is updating in.
    private func attach(to container: NSView) {
        let web = bridge.webView
        guard web.superview !== container else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = true
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
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
            // At most two fifths of the height, so in a small window the
            // source and the PDF keep the room, not the panel.
            SplitPane(minimum: 80, maxFraction: 0.4, fraction: 0.3, keepsSize: true, shown: project.showLogs) {
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
/// text scrolled beneath them was only hidden. The find bar, while it
/// shows, goes between them and the text, as TextEdit's and Xcode's do.
private struct SourcePane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            SourceBar(project: project)
            SourceLocation(project: project)
            if project.findShown {
                Divider()
                SourceFindBar(project: project)
            }
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

/// The status bar: how the build went (choose it for the panel's errors and
/// warnings), the save state and where the cursor is, then the build panel's
/// toggle at the trailing end. The bars' flat controls, at the secondary
/// rows' size. The one place the build's summary shows: the panel's header
/// leaves it out.
private struct StatusBar: View {
    let project: ProjectModel
    @AppStorage("showWordCount") private var showWordCount = true

    var body: some View {
        @Bindable var project = project
        SecondaryBar(spacing: BarMetrics.itemSpacing) {
            Button {
                project.panelTab = .issues
                project.showLogs = true
            } label: {
                buildStatus
            }
            .help("Show Issues")
            .layoutPriority(1)
            Text(project.status)
            Spacer(minLength: BarMetrics.itemSpacing)
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
            ToolSeparator()
            Toggle(isOn: $project.showLogs) {
                Label("Build Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(project.showLogs ? "Hide Build Panel" : "Show Build Panel")
        }
        .buttonStyle(.accessoryBar)
        .foregroundStyle(.secondary)
    }

    /// Only the symbols carry colour; the words stay secondary.
    @ViewBuilder
    private var buildStatus: some View {
        HStack(spacing: BarMetrics.groupSpacing) {
            if project.compiling {
                ProgressView().controlSize(.small)
                Text("Compiling…")
            } else if let result = project.result {
                if result.ok {
                    badge("Compiled in \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    // The error count folds into the failure, so its symbol
                    // shows once.
                    badge(failedTitle, "xmark.octagon.fill", .red)
                }
            } else {
                Text(project.noBuildTitle)
            }
            if project.errorCount > 0, project.result?.ok != false {
                badge("\(project.errorCount)", "xmark.octagon.fill", .red)
                    .accessibilityLabel("\(project.errorCount) errors")
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill", .orange)
                    .accessibilityLabel("\(project.warningCount) warnings")
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private var failedTitle: String {
        switch project.errorCount {
        case 0: "Build Failed"
        case 1: "Build Failed · 1 Error"
        case let count: "Build Failed · \(count) Errors"
        }
    }

    private func badge(_ title: String, _ systemImage: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
    }
}
