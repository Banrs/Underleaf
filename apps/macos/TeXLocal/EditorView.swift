import SwiftUI
import WebKit

/// A project's editor page, its appearance kept in step with the system and Settings.
struct EditorView: View {
    let bridge: EditorBridge
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(EditorPrefs.paletteKey) private var palette: EditorPalette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font: EditorFont = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @FocusState private var focused: Bool

    var body: some View {
        let appearance = EditorAppearance(colorScheme: colorScheme, contrast: contrast,
                                          palette: palette, font: font, fontSize: fontSize)
        WebView(bridge.page)
            // The page draws the text's surface.
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

/// The source column: the source, the build panel below it, and the status bar.
struct EditorArea: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    let fit: ToolbarFit

    var body: some View {
        VStack(spacing: 0) {
            editors
            // Stacked, not overlaid: an overlaid bar hid the editors' last lines.
            Divider()
            StatusBar(project: project)
        }
        .background { ColumnReader(column: .source, fit: fit) }
        .toolbar(id: "source") { toolbar }
    }

    private var editors: some View {
        SplitController(app: app, axis: .vertical, autosave: "PanelSplit", panes: [
            SplitPane(minimum: 120) { SourcePane(project: project) },
            // At most two fifths: in a small window the source keeps the room.
            SplitPane(minimum: 80, maxFraction: 0.4, fraction: 0.25, keepsSize: true, shown: project.showLogs) {
                PanelView(project: project)
            },
        ])
    }

    /// Back and the title lead (HIG, Toolbars); while the PDF is hidden the system
    /// moves its column's items here.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        // Back only: one level, no history to go forward through (HIG, Toolbars).
        ToolbarItem(id: "back", placement: .navigation) {
            Button { app.perform(.projectClose, on: project) } label: {
                Label("Projects", systemImage: "chevron.backward")
            }
            .help("Back to Projects")
            .background { ToolbarProbe(item: .back, fit: fit) }
        }
        .customizationBehavior(.disabled)
        SourceToolbar(app: app, project: project, fit: fit)
    }
}

/// The source, under its find bar while that shows.
private struct SourcePane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        PaneStack(finding: project.findShown) {
            SourceFindBar(project: project)
        } content: {
            // The editor stays mounted under a preview or the placeholder: a
            // WebPage attaches to one WebView, once (27.2).
            let editing = project.openPath != nil && project.editsText
            ZStack {
                EditorView(bridge: project.editor)
                    .opacity(editing ? 1 : 0)
                    .allowsHitTesting(editing)
                    .accessibilityHidden(!editing)
                if project.openPath != nil, !project.editsText, let url = project.openURL {
                    FilePreview(url: url)
                        .background(.background)
                } else if project.openPath == nil {
                    ContentUnavailableView("No File Open", systemImage: "doc.text",
                                           description: Text("Choose a file in the sidebar."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                }
            }
        }
    }
}

/// An image or a PDF figure in place of the editor, fitted but never enlarged;
/// anything else is No Preview, with the way to open it in its own app.
private struct FilePreview: View {
    let url: URL
    @Environment(\.openURL) private var openURL
    /// The image read for `url`, nil when it isn't one.
    @State private var loaded: (url: URL, image: NSImage?)?

    var body: some View {
        Group {
            if !isPreviewFile(url.path) {
                noPreview
            } else if let loaded, loaded.url == url {
                if let image = loaded.image { preview(image) } else { noPreview }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            guard isPreviewFile(url.path) else { return }
            let data = await Self.read(url)
            loaded = (url, data.flatMap(NSImage.init(data:)))
        }
    }

    private func preview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            // A PDF is a page: on white paper, as in the PDF column.
            .background(url.pathExtension.lowercased() == "pdf" ? Color.white : .clear)
            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(url.lastPathComponent)
    }

    private var noPreview: some View {
        ContentUnavailableView {
            Label("No Preview", systemImage: fileSymbol(url.path))
        } description: {
            Text(url.lastPathComponent)
        } actions: {
            Button("Open in Default App") { openURL(url) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @concurrent nonisolated private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }
}

/// The build's summary, the save state and the caret, and the build panel's
/// toggle (HIG, Windows: a status bar). Items drop whole, least important first
/// (ViewThatFits).
private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// Where the window's rounded corners are beside the bar's ends.
    @State private var corners = RectangleCornerInsets()

    var body: some View {
        @Bindable var project = project
        SecondaryBar(spacing: 0,
                     leadingInset: max(BarMetrics.inset, corners.bottomLeading.width),
                     trailingInset: max(BarMetrics.inset, corners.bottomTrailing.width)) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            ToolSeparator()
            ViewThatFits(in: .horizontal) {
                items(save: true, counts: true, engine: true)
                items(save: true, counts: true, engine: false)
                items(save: true, counts: false, engine: false)
                items(save: false, counts: false, engine: false)
            }
            .foregroundStyle(.secondary)
            ToolSeparator()
            Toggle(isOn: $project.showLogs) {
                Label("Build Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .labelStyle(.iconOnly)
            .help(app.title(.viewToggleLogs, on: project))
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .onGeometryChange(for: RectangleCornerInsets.self) { $0.containerCornerInsets } action: { corners = $0 }
        // What the bar shows is chosen where it shows (and View › Show Word Count).
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    private func items(save: Bool, counts showCounts: Bool, engine showEngine: Bool) -> some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            // While a build runs the build status says so. A preview has no save state.
            if save, !project.compiling, project.editsText {
                Text(project.status)
            }
            Spacer(minLength: 0)
            if project.editsText {
                Text("Line \(project.cursorLine)").monospacedDigit()
                if showCounts, app.showWordCount, let counts = project.counts {
                    Text("^[\(counts.words) word](inflect: true) · ^[\(counts.lines) line](inflect: true)")
                        .monospacedDigit()
                }
            }
            if showEngine, let engine = project.settings?.engine {
                Text(texEngineName(engine))
            }
        }
        .lineLimit(1)
    }

    /// Only the symbols carry colour; the words stay secondary.
    private var buildStatus: some View {
        HStack(spacing: BarMetrics.groupSpacing) {
            if project.compiling {
                ProgressView()
                Text("Compiling…")
            } else if let result = project.result {
                if result.stopped {
                    Text("Build Stopped")
                } else if result.ok {
                    badge("Compiled in \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    // The error count folds into the failure, so its symbol shows once.
                    badge(failedTitle, "xmark.octagon.fill", .red)
                }
            } else {
                Text(project.noBuildTitle)
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill", .red)
                    .accessibilityLabel(Text("^[\(project.errorCount) error](inflect: true)"))
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill", .orange)
                    .accessibilityLabel(Text("^[\(project.warningCount) warning](inflect: true)"))
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
