import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("TeXLocal", id: "main") {
            RootView()
                .environment(delegate.app)
        }
        .defaultSize(WindowMetrics.projectDefault)
        // Without it a `Window` scene only zooms, never goes full screen (27.2).
        .windowManagerRole(.principal)
        .commands {
            AppCommands(app: delegate.app)
            ToolbarCommands()
            // The app has no help book; the default item only said so.
            CommandGroup(replacing: .help) {
                Link("TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.app)
        }
    }
}

/// Owns the app model so Quit can wait for the open document's save, and
/// refuse when it fails rather than drop the only copy of the edits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A save in flight has cleared `dirty` before its write is on disk.
        guard let project = app.project, project.hasUnsavedText || project.saving else { return .terminateNow }
        Task {
            sender.reply(toApplicationShouldTerminate: await project.flush())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Compiles run in their own process groups; nothing else stops them.
        Core.shared.killAll()
    }

    /// The app is its one window, so closing it quits (and the quit saves).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Binding where Value == Bool {
    /// For `fileExporter`, which takes a Bool and an item rather than an item binding.
    init<Item: Sendable>(presenting item: Binding<Item?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension View {
    /// Not destructive-styled: the Trash gives the item back (HIG, Alerts).
    func trashConfirmation<Item: Sendable>(_ item: Binding<Item?>, name: @escaping (Item) -> String,
                                           perform: @escaping (Item) -> Void) -> some View {
        confirmationDialog("Move “\(item.wrappedValue.map(name) ?? "")” to the Trash?", item: item,
                           titleVisibility: .visible) { value in
            Button("Move to Trash") { perform(value) }
        } message: { _ in
            Text("You can restore it from the Trash.")
        }
    }
}

/// The window: the projects, or the open project.
struct RootView: View {
    @Environment(AppModel.self) private var app
    /// Restored with the window.
    @SceneStorage("workspace") private var savedWorkspace: Data?

    var body: some View {
        @Bindable var app = app
        // A ZStack, not a Group, so the modifiers below apply once, not per branch.
        ZStack {
            if let project = app.project {
                WorkspaceView(project: project)
            } else {
                HomeView()
            }
        }
        // Constant: a minimum that changes mid-layout loops the split (27.2).
        .frame(minWidth: WindowMetrics.contentMinimum.width, minHeight: WindowMetrics.contentMinimum.height)
        .task {
            // Only the alert below has anything to show.
            guard Core.shared.isOpen else { return }
            await app.refresh()
            let saved = savedWorkspace.flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
                .flatMap { saved in app.projects.contains { $0.id == saved.project } ? saved : nil }
            if let id = app.takeLaunchProject() ?? saved?.project, app.project == nil, !app.isOpening {
                await app.open(id, restoring: saved)
            }
        }
        // Nil once the project closes, so the next launch shows the projects.
        .onChange(of: app.project?.saved) { _, saved in
            savedWorkspace = saved.flatMap { try? JSONEncoder().encode($0) }
        }
        // Open With and Dock drops: imported only once the copy is agreed to.
        .onOpenURL { url in
            if AppModel.canOpen(url) { app.pendingImport = url }
        }
        .alert(app.pendingImport.map { "Copy “\($0.lastPathComponent)” into Your Projects?" } ?? "",
               item: $app.pendingImport) { url in
            Button("Copy and Open") { Task { await app.importProject(from: url) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("TeXLocal opens the copy as a new project. The original stays where it is.")
        }
        // Installing TeX takes effect without a restart, whichever screen shows.
        .task(id: app.tex?.available) { await app.watchForTeX() }
        // On a view of its own: a file dialog's labels reach every dialog
        // presented from the view they're set on.
        .background {
            Color.clear
                .fileImporter(isPresented: $app.openingProject, allowedContentTypes: AppModel.openableTypes) { result in
                    switch result {
                    case .success(let url): Task { await app.importProject(from: url) }
                    case .failure(let error): app.alert = AppAlert("Couldn’t Open the Project", error)
                    }
                }
                .fileDialogConfirmationLabel("Open")
                .fileDialogMessage("Choose a project folder, a .tex file or a .zip. TeXLocal copies it into your projects.")
        }
        .sheet(item: $app.newProjectTemplate) { NewProjectSheet(template: $0.id) }
        .alert($app.alert)
        // Say why and quit, rather than crash with a report that explains nothing.
        .alert("Couldn’t Open the Library Folder", isPresented: .constant(!Core.shared.isOpen)) {
            Button("Quit") { NSApp.terminate(nil) }
        } message: {
            let folder = (Core.libraryFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            Text("Make sure you can create and write to \(folder), then open TeXLocal again.")
        }
    }
}

extension View {
    /// Shows an `AppAlert` while `alert` holds one.
    func alert(_ alert: Binding<AppAlert?>) -> some View {
        self.alert(alert.wrappedValue?.title ?? "", item: alert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

enum WindowMetrics {
    /// The content's minimum, below the toolbar: the columns' minimums fit
    /// (checked in the tests), and the whole window is 960 × 600.
    static let contentMinimum = CGSize(width: 960, height: 548)
    /// Fits the smallest current Mac display's default resolution (1470 × 956)
    /// with the menu bar and Dock.
    static let projectDefault = CGSize(width: 1200, height: 760)
}
