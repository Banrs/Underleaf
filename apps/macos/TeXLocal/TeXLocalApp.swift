import SwiftUI

/// One window, with one project (`AppModel.project`): the projects, or the open project's
/// workspace (`RootView`); and Settings.
@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("TeXLocal", id: "main") {
            RootView()
                .environment(delegate.app)
        }
        // Fits the smallest current Mac display's default resolution (1470 × 956) with the menu bar and Dock.
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(app: delegate.app)
            SidebarCommands()
            InspectorCommands()
            ToolbarCommands()
            // The app has no help book; the default item would only say so.
            CommandGroup(replacing: .help) {
                Link("TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
                // Where Apple's apps put their feedback: Help.
                Link("Report an Issue…", destination: URL(string: "https://github.com/Banrs/Underleaf/issues")!)
            }
        }
        Settings {
            SettingsView()
                .environment(delegate.app)
        }
    }
}

/// Owns the app model. Quit waits for the project's writes, and refuses when a save
/// fails rather than drop the only copy of the edits.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let app = AppModel()

    /// TeX installed meanwhile in another app counts once the user comes back.
    func applicationDidBecomeActive(_ notification: Notification) {
        if app.tex?.available == false { Task { await app.refreshTeXStatus() } }
    }

    /// Open With and Dock drops: imported only once the copy is agreed to.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: AppModel.canOpen) { app.pendingImport = url }
    }

    /// The Dock icon brings the window back, closed or minimised, even while Settings shows,
    /// when the system wouldn't: it has a window then.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app.showWindow()
        return true
    }

    private lazy var dockMenu = DockMenu(app: app) { [unowned self] in
        NSApp.activate()
        app.showWindow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu.menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A clean editor can still have a settings change or rename in flight.
        guard let project = app.project else { return .terminateNow }
        Task {
            let saved = await project.flush()
            // Not saved, the quit stops: the window its alert shows in comes back if
            // closing it began the quit.
            if !saved { app.showWindow() }
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

    // ---------- Edit › Find with neither pane's keyboard ----------

    /// The end of the responder chain: the source text and the PDF (`SyncPDFView`) answer
    /// Edit › Find themselves while they have the keyboard. Elsewhere in the workspace, as in
    /// its sidebar, the source's find bar, or the PDF's over a preview. Nil turns an item off.
    @objc func performFindPanelAction(_ sender: Any?) {
        findAction(for: sender)?()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(performFindPanelAction(_:)) || findAction(for: item) != nil
    }

    private func findAction(for sender: Any?) -> (() -> Void)? {
        // The editor is in the workspace's window, shown or not.
        guard let item = sender as? NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag),
              let project = app.project, project.editor.textView.window?.isKeyWindow == true else { return nil }
        guard project.editsText else {
            guard action == .showFindInterface, project.hasPDF else { return nil }
            return { project.performPDF(.find) }
        }
        let editor = project.editor
        guard editor.textView.validateUserInterfaceItem(item) else { return nil }
        return {
            editor.focus()
            editor.textView.performFindPanelAction(item)
        }
    }
}

/// The Dock icon's menu: the recent projects, newest first, as Pages, Xcode and Preview
/// list their recent documents there. Not the system's recent documents, which come back
/// through `application(_:open:)` as items to copy in. One opens as from Home's Recent
/// list, with the window brought forward.
final class DockMenu: NSObject {
    private let app: AppModel
    private let show: () -> Void

    init(app: AppModel, show: @escaping () -> Void) {
        self.app = app
        self.show = show
    }

    var menu: NSMenu? {
        let recents = app.recents
        guard !recents.isEmpty else { return nil }
        let menu = NSMenu()
        for project in recents {
            let item = NSMenuItem(title: project.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
            menu.addItem(item)
        }
        return menu
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        show()
        Task { await app.open(id) }
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
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("TeXLocal opens the copy as a new project, and a .tex brings the files in its folder. The originals stay where they are.")
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
