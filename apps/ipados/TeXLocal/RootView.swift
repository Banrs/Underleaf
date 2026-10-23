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
    @SceneStorage("project") private var restored: String?

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
            if scenePhase == .active { app.project?.rescan() } else { saveEdits() }
        }
        .onChange(of: app.project?.id) { _, id in restored = id }
        .task {
            app.undoSource = { [undoManager] in undoManager }
            guard Core.shared.isOpen else { return }
            // Before a project opens: its first build needs to know of TeX.
            async let tex: Void = app.refreshTeXStatus()
            await app.refresh()
            await tex
            // Its place is the core's ui state, as the Mac's is.
            let restored = restored.flatMap { id in app.projects.contains { $0.id == id } ? id : nil }
            if let id = app.launchProject.take() ?? restored, app.project == nil, !app.isOpening { await app.open(id) }
        }
    }

    /// iPadOS ends an app put away, or closed from the app switcher, without a word, so what was typed and the project's
    /// place are saved as the window stops being active, as the Mac's are at Quit, in the time a background task gives.
    private func saveEdits() {
        guard let project = app.project else { return }
        let application = UIApplication.shared
        nonisolated(unsafe) var task = UIBackgroundTaskIdentifier.invalid
        // Ended by whichever comes first, as iPadOS ends an app whose time runs out with a task still begun.
        let end: @MainActor @Sendable () -> Void = {
            guard task != .invalid else { return }
            application.endBackgroundTask(task)
            task = .invalid
        }
        task = application.beginBackgroundTask(withName: "Save", expirationHandler: end)
        Task {
            await project.save()
            await project.savePlace()
            end()
        }
    }
}
