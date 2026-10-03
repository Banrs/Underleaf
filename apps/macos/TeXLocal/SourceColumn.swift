import SwiftUI

struct SourceColumn: View {
    let project: ProjectModel
    @AppStorage(EditorPrefs.paletteKey) private var palette: EditorPalette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font: EditorFont = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize

    var body: some View {
        // Keep the editor under previews so it retains its text and scroll position.
        ZStack {
            // AppKit draws the edge effect under the bars and up to the window edge.
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

/// Fit image and PDF previews without enlargement; offer other files to their default app.
private struct FilePreview: View {
    let url: URL
    @Environment(\.openURL) private var openURL
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

struct SourceFindBar: View {
    @Bindable var project: ProjectModel
    let field: FieldHandle
    @State private var replaceField = FieldHandle()

    var body: some View {
        FindBar(query: $project.findQuery.search, prompt: "Find", field: field, options: options,
                matches: project.findMatches, searched: project.findQuery.search,
                step: { project.findStep($0) }, close: { project.closeFind() }) {
            if project.replaceShown {
                GridRow {
                    SearchField(text: $project.findQuery.replace, prompt: "Replace", handle: replaceField, replacing: true,
                                step: { _ in project.editor.replace(all: false) }, close: { project.closeFind() })
                        .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: .infinity)
                        // Wait for AppKit to create the new row's field before focusing it.
                        .task(id: project.replaceFocus) {
                            await Task.yield()
                            if !Task.isCancelled, project.replaceFocus > 0 { replaceField.focus(selectAll: false) }
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
