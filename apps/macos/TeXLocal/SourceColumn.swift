import SwiftUI
import WebKit

/// The project's editor page, one web view the bridge keeps; SwiftUI may rebuild
/// this wrapper, which only hosts it. It runs on under the toolbar and the find
/// bar (`obscuredTop`), where WebKit draws the system's scroll edge effect over
/// the page, which scrolls under them (embed/editor.html).
struct EditorView: NSViewRepresentable {
    let bridge: EditorBridge
    let shown: Bool
    let obscuredTop: CGFloat

    func makeNSView(context: Context) -> WKWebView { bridge.webView }

    func updateNSView(_ view: WKWebView, context: Context) {
        if bridge.shown != shown { bridge.shown = shown }
        if view.obscuredContentInsets.top != obscuredTop { view.obscuredContentInsets.top = obscuredTop }
    }
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
    @State private var obscuredTop: CGFloat = 0

    var body: some View {
        // The editor stays mounted under a preview or the placeholder, so its
        // page keeps the text and its place.
        let editing = project.openPath != nil && project.editsText
        let appearance = EditorAppearance(colorScheme: colorScheme, contrast: contrast,
                                          palette: palette, font: font, fontSize: fontSize)
        ZStack {
            EditorView(bridge: project.editor, shown: editing, obscuredTop: obscuredTop)
                .ignoresSafeArea(.container, edges: .top)
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { obscuredTop = $0 }
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

/// Find and replace in the source; CodeMirror searches, its own panel hidden.
struct SourceFindBar: View {
    @Bindable var project: ProjectModel
    let field: FieldHandle
    @FocusState private var replaceFocused: Bool

    var body: some View {
        FindBar(query: $project.findQuery.search, prompt: "Find", field: field, options: options,
                matches: project.findMatches, searched: project.findQuery.search,
                step: { project.findStep($0) }, close: { project.closeFind() }) {
            if project.replaceShown {
                GridRow {
                    TextField("Replace", text: $project.findQuery.replace, prompt: Text("Replace"))
                        .labelsHidden()
                        // UI kit: a capsule, as the search field over it.
                        .textFieldStyle(.bordered)
                        .textInputBorderShape(.capsule)
                        .onSubmit { project.replace(all: false) }
                        .onExitCommand { project.closeFind() }
                        .focused($replaceFocused)
                        // Find and Replace…, whether or not the bar already shows.
                        .task(id: project.replaceFocus) {
                            if project.replaceFocus > 0 { replaceFocused = true }
                        }
                    HStack {
                        Button("Replace") { project.replace(all: false) }
                        Button("Replace All") { project.replace(all: true) }
                    }
                    .fixedSize()
                    .disabled(project.findMatches.total == 0)
                    .gridColumnAlignment(.trailing)
                }
            }
        }
    }

    private var options: [SearchOption] {
        [
            SearchOption(title: "Match Case", isOn: $project.findQuery.caseSensitive),
            SearchOption(title: "Whole Words", isOn: $project.findQuery.wholeWord),
            SearchOption(title: "Regular Expression", isOn: $project.findQuery.regexp),
        ]
    }
}
