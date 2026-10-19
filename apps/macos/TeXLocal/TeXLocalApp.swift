import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { SettingsView().environment(delegate.app) }
        .commands {
            AppCommands(app: delegate.app)
            ToolbarCommands()
            // The app has no help book; the default item would only say so.
            CommandGroup(replacing: .help) {
                Link("Visit TeXLocal on GitHub", destination: Links.repository)
                Link("Report Issue", destination: Links.issues)
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
        #if DEBUG
        QASnapshot.install()
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        if app.tex?.available == false { Task { await app.refreshTeXStatus() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await app.importProjects(urls.filter(AppModel.canOpen)) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow.window?.isVisible != true { mainWindow.showWindow(nil) }
        return true
    }

    private lazy var dockMenu = DockMenu(app: app) { [unowned self] in
        NSApp.activate()
        mainWindow.showWindow(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu.menu }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            // A clean editor can still have a settings change or rename in flight.
            let saved = await app.project?.save() ?? true
            if saved {
                // Compiles run in their own process groups; nothing else stops them.
                try? await Core.shared.call("kill_all", [:])
            } else if mainWindow.window?.isVisible != true {
                // Not saved, the quit stops: the window its alert shows in comes back if closing it began the quit.
                mainWindow.showWindow(nil)
            }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
            let item = menu.addItem(withTitle: project.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "New Project…", action: #selector(newProject), keyEquivalent: "").target = self
        return menu
    }

    @objc private func newProject() {
        show()
        app.newProject()
    }

    @objc private func open(_ item: NSMenuItem) {
        show()
        Task { await app.open(item.representedObject as! String) }
    }
}
