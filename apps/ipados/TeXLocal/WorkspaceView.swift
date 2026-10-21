import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        NavigationSplitView {
            List(project.tree.nodes.flattened) { node in Text(node.name) }
        } detail: {
            HStack(spacing: 0) {
                EditorView(editor: project.editor, shown: project.editsText)
                Divider()
                PDFRepresentable(project: project)
            }
        }
    }
}
