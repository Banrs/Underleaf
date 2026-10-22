import SwiftUI
import UIKit

/// Home, or the open project's workspace.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var shown: ProjectModel?
    @Binding var settingsShown: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// The window's project, file, line and PDF place, which iPadOS restores with the window, as AppKit does the Mac's.
    @SceneStorage("workspace") private var restoration: Data?

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
        .sheet(isPresented: $settingsShown) { SettingsView() }
        // A .zip or folder another app or the Dock hands over, as the Mac's Finder and Dock do.
        .onOpenURL { url in
            if AppModel.canOpen(url) { Task { await app.open([url]) } }
        }
        // The menus act on the project while its window is in front.
        .onChange(of: scenePhase, initial: true) {
            app.mainWindowIsKey = scenePhase == .active
            if scenePhase != .active { saveEdits() }
        }
        .onChange(of: app.project?.saved) { _, saved in restoration = saved.flatMap { try? JSONEncoder().encode($0) } }
        .task {
            app.undoSource = { [undoManager] in undoManager }
            guard Core.shared.isOpen else { return }
            // Before a project opens: its first build needs to know of TeX.
            async let tex: Void = app.refreshTeXStatus()
            await app.refresh()
            await tex
            let saved = restoration.flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
                .flatMap { saved in app.projects.contains { $0.id == saved.project } ? saved : nil }
            if let id = app.launchProject.take() ?? saved?.project, app.project == nil, !app.isOpening {
                await app.open(id, restoring: saved)
            }
        }
    }

    /// iPadOS ends an app put away, or closed from the app switcher, without a word, so what was typed is saved as the
    /// window stops being active, as the Mac's is at Quit, in the time a background task gives.
    private func saveEdits() {
        guard let project = app.project else { return }
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "Save")
        Task {
            await project.save()
            application.endBackgroundTask(task)
        }
    }
}
