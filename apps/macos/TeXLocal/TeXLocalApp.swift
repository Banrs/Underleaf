import SwiftUI

/// SwiftUI's app: the menus and Settings. The one window is AppKit's
/// (`MainWindowController`), made by the delegate at launch.
@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(delegate.app)
        }
        .commands {
            AppCommands(app: delegate.app)
            ToolbarCommands()
            // The app has no help book; the default item would only say so.
            CommandGroup(replacing: .help) {
                Link("TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
            }
        }
    }
}

/// Owns the app model and the window; Quit waits for the open document's save,
/// and refuses when it fails rather than drop the only copy of the edits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// For window restoration, which asks a class for the window.
    private(set) static weak var shared: AppDelegate?
    let app = AppModel()
    private(set) lazy var mainWindow = MainWindowController(app: app)

    override init() {
        super.init()
        Self.shared = self
    }

    /// After state restoration, which may have made the window already.
    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Open With and Dock drops: imported only once the copy is agreed to.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: AppModel.canOpen) { app.pendingImport = url }
    }

    /// The Dock icon brings the window back, closed or minimised, even while Settings shows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow.window?.isVisible != true { mainWindow.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A save in flight has cleared `dirty` before its write is on disk.
        guard let project = app.project, project.hasUnsavedText || project.saving else { return .terminateNow }
        Task {
            let saved = await project.flush()
            // Not saved, the quit stops: the window its alert shows in comes back if
            // closing it began the quit.
            if !saved, mainWindow.window?.isVisible != true { mainWindow.showWindow(nil) }
            sender.reply(toApplicationShouldTerminate: saved)
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

extension View {
    /// The window's own sheets, alerts and dialogs, whichever screen shows:
    /// File › Open…, New Project…, an item handed to the app, and `AppModel.alert`.
    func windowModals() -> some View {
        modifier(WindowModals())
    }
}

private struct WindowModals: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            .alert(app.pendingImport.map { "Copy “\($0.lastPathComponent)” into Your Projects?" } ?? "",
                   item: $app.pendingImport) { url in
                Button("Copy and Open") { Task { await app.importProject(from: url) } }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("TeXLocal opens the copy as a new project. The original stays where it is.")
            }
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
        // No actions: the system adds its own OK.
        self.alert(alert.wrappedValue?.title ?? "", item: alert) { _ in } message: { alert in
            Text(alert.message)
        }
    }
}
