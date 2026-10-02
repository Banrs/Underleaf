import SwiftUI

/// The source column: the editor, or a preview or placeholder over it. It
/// carries the workspace's sheets and alerts, being the one pane always shown.
struct SourceColumn: View {
    let project: ProjectModel
    @AppStorage(EditorPrefs.paletteKey) private var palette: EditorPalette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font: EditorFont = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize

    var body: some View {
        // The editor stays under a preview or the placeholder, keeping the
        // text and its place.
        ZStack {
            // On under the toolbar, find bar and status bar, where AppKit draws its
            // edge effect over the text, and past the columns' toolbar inset
            // to the window's edge.
            EditorView(editor: project.editor, shown: project.editsText)
                .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
            if project.openPath == nil {
                ContentUnavailableView("No File Open", systemImage: "text.document",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if !project.editsText, let url = project.openURL {
                FilePreview(url: url)
                    .background(.background)
            }
        }
        .onChange(of: EditorAppearance(palette: palette, font: font, size: fontSize), initial: true) { _, appearance in
            project.editor.setAppearance(appearance)
        }
        .modifier(WorkspaceModals(project: project))
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
            // A newer file's read may have finished first.
            if !Task.isCancelled { loaded = (url, data.flatMap(NSImage.init(data:))) }
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

/// Find and replace in the source (`SourceEditor`'s search).
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
                        .onSubmit { project.editor.replace(all: false) }
                        .onExitCommand { project.closeFind() }
                        .focused($replaceFocused)
                        // Find and Replace…, whether or not the bar already shows. After
                        // the update that adds the row: the task starts within it, and
                        // focus asked for there is lost (27.2).
                        .task(id: project.replaceFocus) {
                            await Task.yield()
                            if project.replaceFocus > 0 { replaceFocused = true }
                        }
                    HStack {
                        Button("Replace") { project.editor.replace(all: false) }
                        Button("Replace All") { project.editor.replace(all: true) }
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
