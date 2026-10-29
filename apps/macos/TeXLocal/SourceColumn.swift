import QuickLookUI
import SwiftUI

struct SourceColumn: View {
    @Environment(WorkspaceViews.self) private var views
    let project: ProjectModel

    var body: some View {
        ZStack {
            EditorView(editor: views.editor, shown: project.editsText)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .background(.textSurface)
            if project.openPath == nil {
                ContentUnavailableView("No File Open", systemImage: "text.document",
                                       description: Text("Choose a file in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.textSurface)
            } else if !project.editsText, let url = project.openURL {
                FilePreview(url: url, version: project.previewVersion)
            }
        }
    }
}

private struct EditorView: NSViewRepresentable {
    let editor: SourceEditor
    let shown: Bool
    @Environment(AppModel.self) private var app

    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        if editor.textView.fontSize != CGFloat(app.fontSize) { editor.textView.fontSize = CGFloat(app.fontSize) }
        editor.textView.fontName = app.fontName
        editor.textView.showsLineNumbers = app.lineNumbers
        editor.textView.syntaxTheme = app.syntaxTheme
        editor.textView.autoPair = app.autoPair
        editor.textView.autoComplete = app.autoComplete
        if editor.shown != shown { editor.shown = shown }
    }
}

private struct FilePreview: NSViewRepresentable {
    let url: URL
    let version: Int

    final class Shown { var version = 0 }

    func makeCoordinator() -> Shown { Shown() }
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal) }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.version != version {
            view.refreshPreviewItem()
        }
        context.coordinator.version = version
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Shown) { view.close() }
}
