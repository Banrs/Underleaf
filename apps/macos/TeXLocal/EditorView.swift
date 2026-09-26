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

/// The status bar: how the build went (choose it for the panel's errors and
/// warnings), the save state and where the cursor is, then the build panel's
/// toggle at the trailing end. The bars' flat controls, at the small size.
private struct StatusBar: View {
    let project: ProjectModel
    @AppStorage("showWordCount") private var showWordCount = true

    var body: some View {
        @Bindable var project = project
        HStack(spacing: 12) {
            Button {
                project.panelTab = .issues
                project.showLogs = true
            } label: {
                buildStatus
            }
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
            ToolSeparator()
            Toggle(isOn: $project.showLogs) {
                Label("Build Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(project.showLogs ? "Hide Build Panel" : "Show Build Panel")
        }
        // The small system font (11 pt), as Finder's and Xcode's status bars.
        .font(.subheadline)
        .controlSize(.small)
        .buttonStyle(.accessoryBar)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, BarMetrics.inset)
        .frame(height: BarMetrics.secondaryBarHeight)
        .background(BarMetrics.background)
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
                Text(result.ok ? "Compiled in \(result.durationText)" : "Build Failed")
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
