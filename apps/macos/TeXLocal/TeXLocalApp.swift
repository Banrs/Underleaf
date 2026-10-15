import SwiftUI

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
                Link("Visit TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
                Link("Report Issue", destination: URL(string: "https://github.com/Banrs/Underleaf/issues")!)
            }
        }
    }
}

/// Quit waits for the project's writes, and refuses when a save fails rather than drop the only copy of the edits.
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidBecomeActive(_ notification: Notification) {
        if app.tex?.available == false { Task { await app.refreshTeXStatus() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter(AppModel.canOpen)
        Task {
            for url in urls { await app.importProject(from: url, open: urls.count == 1) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow.window?.isVisible != true { mainWindow.showWindow(nil) }
        return true
    }

    private lazy var dockMenu = DockMenu(app: app) { [unowned self] in
        NSApp.activate()
        mainWindow.showWindow(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu.menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A clean editor can still have a settings change or rename in flight.
        guard let project = app.project else { return .terminateNow }
        Task {
            let saved = await project.save()
            // Not saved, the quit stops: the window its alert shows in comes back if closing it began the quit.
            if !saved, mainWindow.window?.isVisible != true { mainWindow.showWindow(nil) }
            sender.reply(toApplicationShouldTerminate: saved)
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

final class DockMenu: NSObject {
    private let app: AppModel
    private let show: () -> Void

    init(app: AppModel, show: @escaping () -> Void) {
        self.app = app
        self.show = show
    }

    var menu: NSMenu {
        let menu = NSMenu()
        for project in app.recents {
            let item = NSMenuItem(title: project.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let new = NSMenuItem(title: "New Project…", action: #selector(newProject), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    @objc private func newProject() {
        show()
        app.newProject()
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        show()
        Task { await app.open(id) }
    }
}

extension View {
    func windowModals() -> some View {
        modifier(WindowModals())
    }

    func alert(_ alert: Binding<AppAlert?>) -> some View {
        // No actions: the system adds its own OK.
        self.alert(alert.wrappedValue?.title ?? "", item: alert) { _ in } message: { alert in
            Text(alert.message)
        }
    }
}

private struct WindowModals: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            // On a view of its own: a file dialog's labels reach every dialog presented from the view they're set on.
            .background {
                Color.clear
                    .fileImporter(isPresented: $app.openingProject, allowedContentTypes: AppModel.openableTypes) { result in
                        switch result {
                        case .success(let url): Task { await app.importProject(from: url) }
                        case .failure(let error): app.alert = AppAlert("Couldn’t Open the Project", error)
                        }
                    }
                    .fileDialogConfirmationLabel("Open")
                    .fileDialogMessage("Choose a project folder, a .tex file or a .zip. TeXLocal copies it into the projects folder.")
            }
            .sheet(item: $app.newProjectTemplate) { NewProjectSheet(template: $0) }
            .alert($app.alert)
    }
}
