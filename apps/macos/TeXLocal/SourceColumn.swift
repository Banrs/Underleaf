import QuickLookUI
import SwiftUI

struct SourceColumn: View {
    let project: ProjectModel
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @AppStorage(EditorPrefs.syntaxThemeKey) private var syntaxTheme = SyntaxTheme.overleaf

    var body: some View {
        // Keep the editor under previews so it retains its text and scroll position.
        ZStack {
            // SwiftUI's scroll view, as Xcode's editor: under the toolbar and the status bar, with
            // the hard edge under the bar, which draws it in the editor's colour, the text a ghost
            // through it and the system's hairline over it, as Xcode's bar (measured 2026-10-06).
            ScrollView {
                EditorView(editor: project.editor, shown: project.editsText, fontSize: fontSize, syntaxTheme: syntaxTheme)
                    .frame(maxWidth: .infinity)
                    .frame(height: project.editor.layout.height)
            }
            .background(.textSurface)
            .modifier(StatusBarEdge())
            if project.openPath == nil {
                StatusBarGround {
                    ContentUnavailableView("No File Open", systemImage: "text.document",
                                           description: Text("Choose a file in the sidebar."))
                }
            } else if !project.editsText, let url = project.openURL {
                StatusBarGround { FilePreview(url: url) }
            }
        }
        .modifier(WorkspaceModals(project: project))
        .windowModals()
    }
}

/// The status bar's ground for a pane that doesn't scroll in SwiftUI: SwiftUI's hard scroll edge
/// gives the bar the editors' colour, the system's hairline and a ghost of what scrolls beneath,
/// but only over a SwiftUI scroll view (27.2), so the content is one that doesn't scroll, sized
/// to its pane (PDFKit's pages and Quick Look scroll inside their own views).
struct StatusBarGround<Content: View>: View {
    /// Safe areas the content extends under, beyond the bar's.
    var edges: SwiftUI.Edge.Set = []
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(width: geometry.size.width, height: geometry.size.height)
            }
            .scrollDisabled(true)
            .background(.textSurface)
            .modifier(StatusBarEdge())
        }
        .ignoresSafeArea(.container, edges: edges)
    }
}

/// A pane bar's edge on a scroll view: the hard edge where the bar is, the bar's region its
/// own, in place of the one the bar's accessory gives the pane, which would double it.
/// The bar here is a blank the accessory's content sits over; SwiftUI draws the edge only under a
/// bar that draws something itself (measured 2026-10-06: not under `Color.clear`, a `Spacer` or a
/// hidden view, and only after a later layout, if at all), so the blank is a fill the eye can't see.
struct StatusBarEdge: ViewModifier {
    /// The bar's; none, no edge.
    var height = StatusBar.height

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom, spacing: 0) { Rectangle().fill(.white.opacity(0.001)).frame(height: height) }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollEdgeEffectHidden(height == 0, for: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
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
