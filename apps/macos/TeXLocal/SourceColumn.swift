import QuickLookUI
import SwiftUI

struct SourceColumn: View {
    let project: ProjectModel
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @AppStorage(EditorPrefs.syntaxThemeKey) private var syntaxTheme = SyntaxTheme.overleaf

    var body: some View {
        // Keep the editor under previews so it retains its text and scroll position.
        ZStack {
            // SwiftUI's scroll view, under the toolbar and the status bar, which AppKit's edges
            // draw over (the bar's is its accessory's, as over the PDF).
            ScrollView {
                EditorView(editor: project.editor, shown: project.editsText, fontSize: fontSize, syntaxTheme: syntaxTheme)
                    .frame(maxWidth: .infinity)
                    .frame(height: project.editor.layout.height)
            }
            .background(.textSurface)
            if project.openPath == nil {
                ContentUnavailableView("No File Open", systemImage: "text.document",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.textSurface)
            } else if !project.editsText, let url = project.openURL {
                FilePreview(url: url)
            }
        }
        .modifier(WorkspaceModals(project: project))
        .windowModals()
    }
}

/// Quick Look's preview of a file the editor doesn't edit.
private struct FilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
