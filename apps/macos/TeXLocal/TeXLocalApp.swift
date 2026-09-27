import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        // One window: the projects (templates and recents) until one opens,
        // then the project, with a back button to the projects. One project
        // at a time: the editor is one WebPage, which shows in one WebView.
        Window("TeXLocal", id: "main") {
            RootView()
                .environment(app)
                .onAppear { delegate.app = app }
        }
        .defaultSize(WindowMetrics.projectDefault)
        // Full screen, not only zoom, as the app's main window (macOS 27.2
        // gave a `Window` scene only zoom without it).
        .windowManagerRole(.principal)
        .commands {
            AppCommands(app: app)
            // The app has no help book; the default item only said so.
            CommandGroup(replacing: .help) {
                Link("TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Quit waits for the open document to reach disk, and refuses — keeping the
/// window — when it cannot, rather than dropping the only copy of the edits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A save in flight counts: it has cleared `dirty` before its write
        // is on disk.
        guard let project = app?.project, project.dirty || project.saving else { return .terminateNow }
        Task {
            sender.reply(toApplicationShouldTerminate: await project.flush())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Compiles run in their own process groups; nothing else stops them.
        Core.shared.killAll()
    }

    /// The app is its one window: closing it quits, and the quit saves.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Binding where Value == Bool {
    /// True while `item` holds something; set to false, it clears `item`.
    init<Item: Sendable>(presenting item: Binding<Item?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension View {
    /// Asks before moving an item to the Trash. Not destructive-styled: moving
    /// it was chosen, and the Trash gives it back (HIG, Alerts). `presenting`,
    /// so the title keeps its name while the dialog closes.
    func trashConfirmation<Item: Sendable>(_ item: Binding<Item?>, name: @escaping (Item) -> String,
                                           perform: @escaping (Item) -> Void) -> some View {
        confirmationDialog("Move “\(item.wrappedValue.map(name) ?? "")” to the Trash?", isPresented: Binding(presenting: item),
                           titleVisibility: .visible, presenting: item.wrappedValue) { value in
            Button("Move to Trash") { perform(value) }
        } message: { _ in
            Text("You can restore it from the Trash.")
        }
    }
}

/// The window: the projects, or the open project.
struct RootView: View {
    @Environment(AppModel.self) private var app
    /// The open project and where it was left, kept with the window's
    /// restored state: it opens again at launch as it was when the system
    /// restores windows (System Settings › Desktop & Dock › Close windows
    /// when quitting an application, or Quit and Keep Windows).
    @SceneStorage("workspace") private var savedWorkspace: Data?

    var body: some View {
        @Bindable var app = app
        // One view whatever it holds, so what follows is the window's and
        // runs once: a Group would hand it to each branch in turn.
        ZStack {
            if let project = app.project {
                WorkspaceView(project: project)
            } else {
                HomeView()
            }
        }
        // One minimum for the window whatever it shows. A minimum that
        // changed with the content (raised as a project opened) landed
        // mid-layout on the split view, whose constraint passes then looped
        // until AppKit threw.
        .frame(minWidth: WindowMetrics.minimum.width, minHeight: WindowMetrics.contentMinHeight)
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
        // A .tex file, a .zip or a folder from Finder's Open With or the
        // Dock icon, opened as Open… opens it once the copy is agreed to.
        .onOpenURL { url in
            if AppModel.canOpen(url) { app.pendingImport = url }
        }
        .alert(app.pendingImport.map { "Copy “\($0.lastPathComponent)” into Your Projects?" } ?? "",
               isPresented: Binding(presenting: $app.pendingImport), presenting: app.pendingImport) { url in
            Button("Copy and Open") { Task { await app.importProject(from: url) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("TeXLocal opens the copy as a new project. The original stays where it is.")
        }
        // While TeX is missing, look for it now and then, whichever screen
        // shows, so installing it takes effect without a restart.
        .task(id: app.tex?.available) { await app.watchForTeX() }
        // On a view of its own: a file dialog's labels reach every dialog
        // presented from inside the view they're set on.
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
        // The library folder can't be made or opened: say so and quit, rather
        // than leave a crash report that explains nothing.
        .alert("Couldn’t Open the Library Folder", isPresented: .constant(!Core.shared.isOpen)) {
            Button("Quit") { NSApp.terminate(nil) }
        } message: {
            let folder = ProcessInfo.processInfo.environment["TEXLOCAL_DATA"] ?? "~/TeXLocal"
            Text("Make sure you can create and write to \(folder), then open TeXLocal again.")
        }
    }
}

extension View {
    /// An `AppAlert` while `alert` holds one. The title says what happened,
    /// briefly, as the HIG asks; the detail is the message. `presenting`,
    /// so the text stays while the alert closes.
    func alert(_ alert: Binding<AppAlert?>) -> some View {
        self.alert(alert.wrappedValue?.title ?? "", isPresented: Binding(presenting: alert),
                   presenting: alert.wrappedValue) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// The window's minimum: 960 × 600 as a whole window, with room for every
/// column at its own: navigator 200, source and PDF together 441, inspector
/// 220. The content's minimum height leaves out the toolbar, which the
/// window adds above it (the unified toolbar is 52 pt), so a 600 pt minimum
/// on the content made the smallest window 652 pt tall.
enum WindowMetrics {
    static let minimum = CGSize(width: 960, height: 600)
    static let toolbarHeight: CGFloat = 52
    static var contentMinHeight: CGFloat { minimum.height - toolbarHeight }

    /// The window opens with room to spare around its columns' minimums,
    /// and inside the smallest current Mac display's default resolution (the
    /// 13-inch MacBook Air's 1470 × 956) with the menu bar and Dock.
    static let projectDefault = CGSize(width: 1200, height: 760)
}
