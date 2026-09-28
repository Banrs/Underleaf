import SwiftUI
import WebKit

/// The project's editor page, one web view the bridge keeps; SwiftUI may rebuild
/// this wrapper, which only hosts it.
struct EditorView: NSViewRepresentable {
    let bridge: EditorBridge

    func makeNSView(context: Context) -> WKWebView { bridge.webView }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The source column: the editor, or a preview or placeholder over it. It
/// carries the workspace's sheets and alerts, being the one pane always shown.
struct SourceColumn: View {
    let project: ProjectModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(EditorPrefs.paletteKey) private var palette: EditorPalette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font: EditorFont = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize

    var body: some View {
        // The editor stays mounted under a preview or the placeholder, so its
        // page keeps the text and its place.
        let editing = project.openPath != nil && project.editsText
        let appearance = EditorAppearance(colorScheme: colorScheme, contrast: contrast,
                                          palette: palette, font: font, fontSize: fontSize)
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
        .task(id: appearance) { await project.editor.setAppearance(appearance) }
        .workspaceModals(project)
        .windowModals()
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

/// Shows and hides the build panel, at the status bar's far end, as a panel's
/// toggle sits at its window's edge.
private struct BuildPanelToggle: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        Toggle(isOn: $project.showLogs) {
            Label("Build Panel", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .help(app.title(.viewToggleLogs, on: project))
    }
}

/// The status bar under the source and the PDF: the build's summary, which shows
/// its issues; the word count (View › Show Word Count); whether the PDF is out of
/// date, and its page, which opens Go to Page; and the build panel's toggle at the
/// far end. The PDF's own page
/// numbers, not LaTeX's (front matter and roman numbers differ). Not here: the save
/// state (edits save themselves 0.7 s after typing stops, as in Notes; a failed save
/// is an alert), the caret's line (the gutter marks it) and the engine (the inspector).
struct StatusBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    let pdf: PDFController

    var body: some View {
        SecondaryBar(spacing: BarMetrics.itemSpacing) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            Spacer(minLength: 0)
            if project.editsText, app.showWordCount, let counts = project.counts {
                Text("^[\(counts.words) word](inflect: true)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .layoutPriority(-1)
            }
            if project.showPDF, project.pdfVersion > 0, pdf.pageCount > 0 {
                if let freshness = project.pdfFreshness { freshnessButton(freshness) }
                Button("Page \(pdf.page) of \(pdf.pageCount)") { app.perform(.pdfGotoPage, on: project) }
                    .monospacedDigit()
                    .help("Go to Page")
            }
            BuildPanelToggle(project: project)
        }
        .buttonStyle(.borderless)
        // What the bar shows is chosen where it shows (and View › Show Word Count).
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    /// Why the pages may not match the source, by the page they concern: edits since
    /// the build (Compile), or the last build that worked after one that failed.
    private func freshnessButton(_ freshness: PDFFreshness) -> some View {
        Button {
            if freshness == .edited { app.perform(.compileRun, on: project) } else { project.showBuildPanel() }
        } label: {
            Label(freshness.title, systemImage: freshness.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .help(freshness == .edited ? "The preview doesn’t reflect the current source. Compile"
                                   : "The latest build failed; this is the last one that succeeded. Show Issues")
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
