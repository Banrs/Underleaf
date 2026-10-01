import QuickLookUI
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
            // On under the toolbar and the find bar, where AppKit draws its
            // edge effect over the text, and past the columns' toolbar inset
            // to the window's edge.
            EditorView(editor: project.editor, shown: project.editsText)
                .ignoresSafeArea(.container, edges: [.top, .trailing])
            if project.openPath == nil {
                ContentUnavailableView("No File Open", systemImage: "text.document",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if !project.editsText, let url = project.openURL {
                FilePreview(url: url, revision: project.previewRevision)
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

/// An image or PDF in place of the editor; other files can be opened in their app.
private struct FilePreview: View {
    let url: URL
    let revision: Int
    @Environment(\.openURL) private var openURL

    var body: some View {
        if isPreviewFile(url.path) {
            QuickLookPreview(url: url, revision: revision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        } else {
            noPreview
        }
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
}

/// Quick Look supplies the system preview controls and native image/PDF gestures.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    final class Coordinator {
        var url: URL?
        var revision: Int?

        init() {}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Preview Unavailable")
        }
        view.previewItem = url as NSURL
        context.coordinator.url = url
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? QLPreviewView else { return }
        if context.coordinator.url != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.revision != revision {
            view.refreshPreviewItem()
        }
        context.coordinator.url = url
        context.coordinator.revision = revision
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        (view as? QLPreviewView)?.close()
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
