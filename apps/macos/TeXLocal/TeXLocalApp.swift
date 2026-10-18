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
        guard let id = item.representedObject as? String else { return }
        show()
        Task { await app.open(id) }
    }
}

extension View {
    func windowModals() -> some View { modifier(WindowModals()) }

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
            .sheet(item: $app.newProjectDraft) { NewProjectSheet(draft: $0) }
            .alert($app.alert)
    }
}

#if DEBUG
/// QA without the screen (debug builds): with TEXLOCAL_QA_SNAPSHOT set to a folder, the distributed notification
/// "com.texlocal.qa.snapshot" (its object a name) writes each visible window as the app draws it, at the backing
/// scale (<name>-<n>.png), and the window's views with their frames in window points (<name>-<n>.txt).
enum QASnapshot {
    static func install() {
        guard let folder = ProcessInfo.processInfo.environment["TEXLOCAL_QA_SNAPSHOT"] else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.texlocal.qa.snapshot"), object: nil, queue: .main) { note in
            let name = note.object as? String ?? "snapshot"
            MainActor.assumeIsolated { write(to: URL(filePath: folder), name: name) }
        }
        // "com.texlocal.qa.resize" (its object "<width>x<height>") sets the main window's content size, as a drag's end would.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.texlocal.qa.resize"), object: nil, queue: .main) { note in
            let size = (note.object as? String ?? "").split(separator: "x").compactMap { Double($0) }
            guard size.count == 2 else { return }
            MainActor.assumeIsolated {
                NSApp.windows.first { $0.isVisible && $0.toolbar != nil }?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
        }
    }

    private static func write(to folder: URL, name: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let frame = window.contentView?.superview ?? window.contentView,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(index).png"))
            var lines = ["\(type(of: window)) \(window.frame) scale \(window.backingScaleFactor)"]
            func walk(_ view: NSView, _ depth: Int) {
                let rect = view.convert(view.bounds, to: nil)
                let extra = (view as? NSControl).map { " font \($0.font?.fontName ?? "-") \($0.font?.pointSize ?? 0)" } ?? ""
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(rect)\(view.isHidden ? " hidden" : "")\(extra)")
                view.subviews.forEach { walk($0, depth + 1) }
            }
            walk(frame, 0)
            try? lines.joined(separator: "\n").write(to: folder.appending(path: "\(name)-\(index).txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
