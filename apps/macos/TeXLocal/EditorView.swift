import SwiftUI
import WebKit

/// The app's one editor page, in SwiftUI's web view, its appearance kept
/// in step with the system and Settings.
struct EditorView: View {
    let bridge: EditorBridge
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(EditorPrefs.paletteKey) private var palette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @FocusState private var focused: Bool

    var body: some View {
        let appearance = EditorAppearance(theme: colorScheme == .dark ? "dark" : "light",
                                          palette: palette, font: font, fontSize: fontSize)
        WebView(bridge.page)
            // The page draws the text's surface itself.
            .webViewContentBackground(.hidden)
            // A text editor: no page zoom, history swipes or link previews.
            .webViewMagnificationGestures(.disabled)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewLinkPreviews(.disabled)
            .focused($focused)
            .onChange(of: bridge.focusRequest) { focused = true }
            .task(id: appearance) { await bridge.setAppearance(appearance) }
    }
}

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
/// shows, goes between them and the text, as TextEdit's and Xcode's do. A
/// file that isn't text has no formatting bar, only its location row.
private struct SourcePane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            if project.openPath == nil || project.editsText {
                SourceBar(project: project)
                Divider()
            }
            SourceLocation(project: project)
            if project.findShown {
                Divider()
                SourceFindBar(project: project)
                    .transition(.findBar(reduceMotion: reduceMotion))
            }
            Divider()
            if project.openPath != nil, !project.editsText, let url = project.openURL {
                FilePreview(url: url)
            } else if project.openPath != nil {
                EditorView(bridge: app.editor)
            } else {
                // No file open, or it was deleted: nothing to type into
                // (workspace.js `showEditorPlaceholder`).
                ContentUnavailableView("No File Open", systemImage: "doc.text",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.snappy(duration: 0.25), value: project.findShown)
    }
}

/// An image or a PDF figure in place of the editor, as the web previews
/// one: fitted to the pane but never enlarged past its own size, as Xcode
/// shows an image. A PDF is a page, so on white paper as the PDF pane's.
/// Any other file, or one that can't be read as an image, is No Preview,
/// with the way to open it in its own app.
private struct FilePreview: View {
    let url: URL

    var body: some View {
        if isPreviewFile(url.path), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .background(url.pathExtension.lowercased() == "pdf" ? Color.white : .clear)
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(url.lastPathComponent)
        } else {
            ContentUnavailableView {
                Label("No Preview", systemImage: fileSymbol(url.path))
            } description: {
                Text(url.lastPathComponent)
            } actions: {
                Button("Open in Default App") { NSWorkspace.shared.open(url) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The status bar, as Finder's is: a little text about the window's
/// contents (HIG, Windows). How the build went (choose it for the panel's
/// issues), the save state and where the cursor is, then, past a line, the
/// build panel's toggle. Both are accessory-bar buttons, as the location
/// row's crumbs and Xcode's jump bar are: flat at rest, a fill under the
/// pointer so what can be clicked shows, and the toggle filled while the
/// panel shows (NSBezelStyleAccessoryBar, "buttons with togglable state").
/// The one place the build's summary shows. A narrow window drops whole
/// items, never cutting one short: the engine first (the inspector and the
/// Compile menu show it too), then the counts, then the save state.
private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        @Bindable var project = project
        // Clear of the window's rounded corners where it meets them (the
        // leading one with the sidebar hidden, the trailing one with the
        // inspector hidden), by the system's own corner insets.
        let corners = app.windowCorners
        // The items, the line and the toggle a group's 8 pt apart: the
        // line has the same room either side.
        SecondaryBar(spacing: BarMetrics.groupSpacing,
                     leadingInset: max(BarMetrics.inset, corners.bottomLeading.width),
                     trailingInset: app.showInspector ? BarMetrics.inset
                         : max(BarMetrics.inset, corners.bottomTrailing.width)) {
            ViewThatFits(in: .horizontal) {
                items(save: true, counts: true, engine: true)
                items(save: true, counts: true, engine: false)
                items(save: true, counts: false, engine: false)
                items(save: false, counts: false, engine: false)
            }
            // The text only: the toggle keeps its style's own on state.
            .foregroundStyle(.secondary)
            ToolSeparator()
            Toggle(isOn: $project.showLogs) {
                Label("Build Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(app.title(.viewToggleLogs))
        }
        .buttonStyle(.accessoryBar)
        // What the bar shows is chosen where it shows, as Pages' word count
        // is (View › Show Word Count too), not in Settings.
        .contextMenu {
            Button(app.showWordCount ? "Hide Word Count" : "Show Word Count") { app.showWordCount.toggle() }
        }
    }

    private func items(save: Bool, counts showCounts: Bool, engine showEngine: Bool) -> some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            Button { project.showBuildPanel() } label: {
                buildStatus
            }
            .help("Show Issues")
            // While a build runs the build status says so; the save state
            // would repeat it. A preview has none, as the web's.
            if save, !project.compiling, project.editsText {
                Text(project.status)
            }
            Spacer(minLength: BarMetrics.itemSpacing)
            if project.editsText {
                Text("Line \(project.cursorLine)").monospacedDigit()
                if showCounts, app.showWordCount, let counts = project.counts {
                    // Singular for one, by Foundation's grammar agreement.
                    Text("^[\(counts.words) word](inflect: true) · ^[\(counts.lines) line](inflect: true)")
                        .monospacedDigit()
                }
            }
            if showEngine, let engine = project.settings?.engine {
                Text(texEngines.first { $0.0 == engine }?.1 ?? engine)
            }
        }
        .lineLimit(1)
    }

    /// Only the symbols carry colour; the words stay secondary.
    private var buildStatus: some View {
        HStack(spacing: BarMetrics.groupSpacing) {
            if project.compiling {
                ProgressView().controlSize(.small)
                Text("Compiling…")
            } else if let result = project.result {
                if result.stopped {
                    Text("Build Stopped")
                } else if result.ok {
                    badge("Compiled in \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    // The error count folds into the failure, so its symbol
                    // shows once.
                    badge(failedTitle, "xmark.octagon.fill", .red)
                }
            } else {
                Text(project.noBuildTitle)
            }
            if project.errorCount > 0, project.result?.failed != true {
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
        .animation(.default, value: project.compiling)
        .animation(.default, value: project.result?.ok)
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

extension AnyTransition {
    /// A find bar sliding down from the bar over it; a dissolve with Reduce
    /// Motion, as the HIG asks of slides.
    static func findBar(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}
