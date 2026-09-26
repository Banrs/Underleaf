import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("TeXLocal", id: "main") {
            RootView()
                .environment(app)
                .onAppear { delegate.app = app }
        }
        .defaultSize(width: 1200, height: 760)
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A save in flight counts: it has cleared `dirty` before its write
        // is on disk.
        guard let project = app?.project, project.dirty || project.saving else { return .terminateNow }
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: await project.flush())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Compiles run in their own process groups; nothing else stops them.
        Core.shared.killAll()
    }

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

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let project = app.project {
                WorkspaceView(project: project)
            } else {
                HomeView()
            }
        }
        // One minimum for the window whatever it shows, with room for every
        // column at its own: navigator 200, source and PDF together 441,
        // inspector 220. A minimum that changed with the content — raised as
        // a project opened — landed mid-layout on the split view, whose
        // constraint passes then looped until AppKit threw.
        .frame(minWidth: WindowMetrics.minimum.width, minHeight: WindowMetrics.contentMinHeight)
        .task {
            // Only the alert below has anything to show.
            guard Core.shared.isOpen else { return }
            await app.refresh()
            // `open TeXLocal.app --args -openProject <id>` opens a project at
            // launch; launch arguments land in UserDefaults' argument domain
            // for this run only.
            if let id = UserDefaults.standard.string(forKey: "openProject"), app.project == nil {
                await app.open(id)
            }
        }
        // While TeX is missing, look for it now and then, whichever screen
        // shows, so installing it takes effect without a restart.
        .task(id: app.tex?.available) { await app.watchForTeX() }
        .fileImporter(isPresented: $app.openingProject, allowedContentTypes: AppModel.openableTypes) { result in
            switch result {
            case .success(let url): Task { await app.importProject(from: url) }
            case .failure(let error): app.alert = AppAlert("Couldn’t Open the Project", error)
            }
        }
        .fileDialogConfirmationLabel("Open")
        .fileDialogMessage("Choose a project folder, a .tex file or a .zip. TeXLocal copies it into your projects.")
        .sheet(item: $app.newProjectTemplate) { NewProjectSheet(template: $0.id) }
        // The title says what happened, briefly, as the HIG asks; the
        // detail is the message. `presenting`, so the text stays while the
        // alert closes.
        .alert(app.alert?.title ?? "", isPresented: Binding(presenting: $app.alert), presenting: app.alert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
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

/// The window's one minimum size, 960 × 600 as a whole window. The content's
/// minimum height leaves out the toolbar, which the window adds above it
/// (the unified toolbar is 52 pt in both windows), so a 600 pt minimum on
/// the content made the smallest window 652 pt tall.
enum WindowMetrics {
    static let minimum = CGSize(width: 960, height: 600)
    static let toolbarHeight: CGFloat = 52
    static var contentMinHeight: CGFloat { minimum.height - toolbarHeight }
}

extension NSApplication {
    /// The project window (the "main" scene's), even while Settings is key.
    var projectWindow: NSWindow? {
        windows.first { $0.identifier?.rawValue == "main" }
    }
}
