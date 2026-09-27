import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        // Office's start window: templates and recent projects. It shows at
        // launch when nothing is restored, and when the Dock icon is clicked
        // with no window open. Restored only when it was open: it closes as
        // a project opens. Not `.restorationBehavior(.disabled)`: saved state
        // that held only the gallery (a crash, or Quit and Keep Windows)
        // then restored nothing, and a launch with saved state presents
        // nothing by default, so the app opened with no window (macOS 27.2).
        Window("Projects", id: AppScene.gallery) {
            GalleryWindow()
                .environment(app)
                .onAppear { delegate.app = app }
        }
        .defaultSize(WindowMetrics.galleryDefault)
        .defaultLaunchBehavior(.presented)
        .commands {
            AppCommands(app: app)
            // The app has no help book; the default item only said so.
            CommandGroup(replacing: .help) {
                Link("TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
            }
        }

        // The open project, one at a time: the editor is one WebPage, which
        // shows in one WebView. Opened by opening a project, and restored
        // with it; never at launch or from the Window menu, where it would
        // open empty only to close again.
        Window("Project", id: AppScene.project) {
            ProjectWindow()
                .environment(app)
                .onAppear { delegate.app = app }
        }
        .defaultSize(WindowMetrics.projectDefault)
        .defaultLaunchBehavior(.suppressed)
        // The app's main window, though not its first scene: without it, a
        // second Window only zooms, with no full screen (macOS 27.2).
        .windowManagerRole(.principal)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// The two windows' scene ids, for `openWindow` and `dismissWindow`.
enum AppScene {
    static let gallery = "gallery"
    static let project = "project"
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
        app?.quitting = true
        // Compiles run in their own process groups; nothing else stops them.
        Core.shared.killAll()
    }

    /// Closing the last window leaves the app running, as Office does: the
    /// Dock icon and File › New and Open bring the gallery back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

/// The gallery's window: where projects are made and opened. File › New
/// Project… and Open…, and Open With, bring it forward to ask there, as
/// Office's do; a project opened from anywhere takes its place.
struct GalleryWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        @Bindable var app = app
        HomeView()
            .frame(minWidth: WindowMetrics.galleryMinimum.width, minHeight: WindowMetrics.galleryContentMinHeight)
            .task {
                // Only the alert below has anything to show.
                guard Core.shared.isOpen else { return }
                await app.refresh()
                if let id = app.takeLaunchProject() { await app.open(id) }
            }
            // A project opened, here or from the menus: its window takes
            // this one's place.
            .onChange(of: app.project.map(ObjectIdentifier.init)) { _, opened in
                guard opened != nil else { return }
                openWindow(id: AppScene.project)
                dismissWindow(id: AppScene.gallery)
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
            // While TeX is missing, look for it now and then, whichever
            // window shows, so installing it takes effect without a restart.
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
            // With no project open, this is the app's window; with one, it
            // shows what failed here.
            .appAlert(shown: app.project == nil || app.alertInGallery)
            .onChange(of: appearsActive, initial: true) { _, active in app.galleryInFront = active }
            // Gone, so the project's window shows what it had.
            .onDisappear {
                app.galleryInFront = false
                app.alertInGallery = false
            }
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

/// The project window. Closing it (⌘W, or File › Close Project) saves and
/// closes the project, and the gallery comes back.
struct ProjectWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// The open project and where it was left, kept with the window's
    /// restored state: it opens again at launch as it was when the system
    /// restores windows (System Settings › Desktop & Dock › Close windows
    /// when quitting an application, or Quit and Keep Windows).
    @SceneStorage("workspace") private var savedWorkspace: Data?

    var body: some View {
        // One view whatever it holds, so what follows is the window's and
        // runs once: a Group would hand it to each branch in turn.
        ZStack {
            if let project = app.project {
                WorkspaceView(project: project)
            }
        }
        .frame(minWidth: WindowMetrics.minimum.width, minHeight: WindowMetrics.contentMinHeight)
        .task {
            // Restored at launch: open the project it held, unless another
            // is already on its way (a launch argument, or Open Recent).
            guard app.project == nil else { return }
            if Core.shared.isOpen {
                await app.refresh()
                let saved = savedWorkspace.flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
                    .flatMap { saved in app.projects.contains { $0.id == saved.project } ? saved : nil }
                if let id = app.takeLaunchProject() ?? saved?.project, app.project == nil, !app.isOpening {
                    await app.open(id, restoring: saved)
                }
            }
            // Nothing to show: the gallery instead.
            if app.project == nil, !app.isOpening { dismissWindow(id: AppScene.project) }
        }
        // From the start too: a window reopened after a failed close, or
        // opened once the project had loaded, has nothing saved yet. Never
        // nil over it: at launch that is the state still to restore.
        .onChange(of: app.project?.saved, initial: true) { _, saved in
            if let saved, let data = try? JSONEncoder().encode(saved) { savedWorkspace = data }
        }
        // Asked for in the menus while the gallery was closed.
        .onChange(of: app.newProjectTemplate != nil || app.openingProject || app.pendingImport != nil) { _, asked in
            if asked { openWindow(id: AppScene.gallery) }
        }
        // The window closed: save and leave the project, and back to the
        // gallery. A save that fails keeps the project, and its window comes
        // back with the alert that says why.
        .onDisappear {
            Task {
                // Quitting takes the window too: its project stays, to be
                // restored with it, and the quit saves it.
                guard !app.quitting else { return }
                let closed = await app.close()
                openWindow(id: closed ? AppScene.gallery : AppScene.project)
            }
        }
        .task(id: app.tex?.available) { await app.watchForTeX() }
        .appAlert(shown: app.project != nil && !app.alertInGallery)
    }
}

extension View {
    /// What went wrong (`AppModel.alert`), in the window it belongs to
    /// (`AppModel.alertInGallery`).
    func appAlert(shown: Bool) -> some View {
        modifier(AppAlertPresenter(shown: shown))
    }

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

private struct AppAlertPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    let shown: Bool

    func body(content: Content) -> some View {
        @Bindable var app = app
        content.alert(shown ? $app.alert : .constant(nil))
    }
}

/// Each window's minimum. The project window's is 960 × 600 as a whole
/// window, with room for every column at its own: navigator 200, source
/// and PDF together 441, inspector 220. It holds whatever the window shows:
/// one raised as a project opened landed mid-layout on the split view, whose
/// constraint passes then looped until AppKit threw. The content's minimum
/// height leaves out the toolbar, which the window adds above it (the
/// unified toolbar is 52 pt in both windows), so a 600 pt minimum on the
/// content made the smallest window 652 pt tall.
enum WindowMetrics {
    static let minimum = CGSize(width: 960, height: 600)
    static let toolbarHeight: CGFloat = 52
    static var contentMinHeight: CGFloat { minimum.height - toolbarHeight }

    /// The project window opens with room to spare around its columns'
    /// minimums, and inside the smallest current Mac display's default
    /// resolution (the 13-inch MacBook Air's 1470 × 956) with the menu bar
    /// and Dock.
    static let projectDefault = CGSize(width: 1200, height: 760)

    /// The gallery's, as a whole window: the four template cards uncropped
    /// and two rows of the recent list, measured on macOS 27.2 (the cards end
    /// 562 pt from the leading edge, then the gallery's 18 pt margin; the
    /// second row ends 478 pt down). It opens at the project window's
    /// minimum, the size it had at the least before it had a window of its
    /// own.
    static let galleryMinimum = CGSize(width: 580, height: 480)
    static var galleryContentMinHeight: CGFloat { galleryMinimum.height - toolbarHeight }
    static let galleryDefault = minimum
}

