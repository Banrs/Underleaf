import SwiftUI

/// Home, or the open project's workspace.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var shown: ProjectModel?

    var body: some View {
        Group {
            if let project = app.workspaceProject(after: shown) {
                WorkspaceView(project: project)
            } else {
                HomeView()
            }
        }
        .onChange(of: app.workspaceProject(after: shown).map(ObjectIdentifier.init)) { shown = app.workspaceProject(after: shown) }
        .alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK") { app.alert = nil }
        } message: {
            Text(app.alert?.message ?? "")
        }
        .task {
            app.undoSource = { [undoManager] in undoManager }
            await app.refresh()
            await app.refreshTeXStatus()
        }
    }
}
