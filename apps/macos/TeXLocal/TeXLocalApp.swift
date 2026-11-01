import SwiftUI
import UniformTypeIdentifiers

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { SettingsView().environment(delegate.app) }
        .commands {
            AppCommands(app: delegate.app)
            ToolbarCommands()
            SidebarCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static weak var shared: AppDelegate?
    let app = AppModel(core: .shared)

    override init() {
        super.init()
        Self.shared = self
        NSWindow.allowsAutomaticWindowTabbing = false
        app.recentLimit = { NSDocumentController.shared.maximumRecentDocumentCount }
        app.newWindow = { [app] id in id.map { MainWindowController(app: app, project: $0).model } ?? HomeWindowController(app: app).model }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard app.core.isOpen else {
            for window in app.windows { window.controller?.close() }
            app.showHome()
            return
        }
        if app.windows.isEmpty { app.showHome() }
        Task { [app] in
            await app.reloadProjects()
            for window in app.windows { await window.reopen() }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        let pdfApp = NSWorkspace.shared.urlForApplication(toOpen: .pdf)
        let name = pdfApp.flatMap { try? $0.resourceValues(forKeys: [.localizedNameKey]).localizedName }
        if name != app.pdfAppName { app.pdfAppName = name }
        if app.tex?.available == false { Task { await app.refreshTeXStatus() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await app.front.open(urls.filter(AppModel.canOpen)) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.front.controller?.show() }
        return true
    }

    private lazy var dockMenu = DockMenu(app: app)

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu.menu }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { sender.reply(toApplicationShouldTerminate: await app.quit()) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class DockMenu: NSObject {
    private let app: AppModel

    init(app: AppModel) { self.app = app }

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
        NSApp.activate()
        let window = app.front
        window.controller?.show()
        window.newProject()
    }

    @objc private func open(_ item: NSMenuItem) {
        NSApp.activate()
        let (window, id) = (app.front, item.representedObject as! String)
        Task { await window.open(id) }
    }
}
