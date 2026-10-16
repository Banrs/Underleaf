import QuickLookUI
import SwiftUI

struct SourceColumn: View {
    let project: ProjectModel
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.overleaf
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true

    var body: some View {
        // Keep the editor under previews so it retains its text and scroll position.
        ZStack {
            EditorView(editor: project.editor, shown: project.editsText, fontName: fontName, fontSize: fontSize,
                       lineNumbers: lineNumbers, syntaxTheme: syntaxTheme, autoPair: autoPair, autoComplete: autoComplete)
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
        .modifier(WorkspaceModals(project: project))
        .windowModals()
    }
}

private struct FilePreview: NSViewRepresentable {
    let url: URL
    let version: Int

    final class Shown {
        var version = 0
    }

    func makeCoordinator() -> Shown { Shown() }

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.version != version {
            view.refreshPreviewItem()
        }
        context.coordinator.version = version
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Shown) {
        view.close()
    }
}
