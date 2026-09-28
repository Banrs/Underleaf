import AppKit
import SwiftUI

/// The app's one window: the projects until one opens, then the project. AppKit's
/// window, so the project's split and toolbar can be AppKit's (`WorkspaceController`);
/// SwiftUI draws the projects screen, with its own toolbar bridged in, and every pane.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let app: AppModel
    /// Made each time the projects show and let go when a project opens, so one
    /// screen's alerts and sheets never wait in another's views.
    private var home: NSHostingController<HomeRoot>?
    private(set) var workspace: WorkspaceController?
    /// Where the restored window was left, opened once the library is in.
    private var restored: SavedWorkspace?
    private var watches: [Task<Void, Never>] = []
    private var titleWatch: Task<Void, Never>?
    /// Polls for TeX while it's missing; one at a time.
    private var texWatch: Task<Void, Never>?
    /// The find bars' fields' field editor (`FindFieldEditor`).
    private let findEditor: FindFieldEditor = {
        let editor = FindFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    init(app: AppModel) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowMetrics.projectDefault),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.identifier = Self.identifier
        window.restorationClass = Self.self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        showHome()
        window.center()
        // After centring: a frame saved by an earlier launch wins.
        window.setFrameAutosaveName("Main Window")
        watches = [
            track({ [app] in app.project.map(ObjectIdentifier.init) }) { [weak self] _ in self?.showProject() },
            track({ [app] in app.project?.saved }) { [weak self] _ in self?.window?.invalidateRestorableState() },
            // Installing TeX takes effect without a restart, whichever screen shows.
            track({ [app] in app.tex?.available }) { [weak self, app] available in
                self?.texWatch?.cancel()
                self?.texWatch = available == false ? Task { await app.watchForTeX() } : nil
            },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        watches.forEach { $0.cancel() }
        titleWatch?.cancel()
        texWatch?.cancel()
    }

    /// Shows the window, then loads the library and opens the project the launch
    /// argument names, or the one the restored window was left on.
    func start() {
        showWindow(nil)
        guard Core.shared.isOpen else { return }
        Task {
            await app.refresh()
            let saved = restored.flatMap { saved in app.projects.contains { $0.id == saved.project } ? saved : nil }
            restored = nil
            if let id = app.takeLaunchProject() ?? saved?.project, app.project == nil, !app.isOpening {
                await app.open(id, restoring: saved)
            }
        }
    }

    // ---------- content ----------

    /// The open project's workspace, or the projects.
    private func showProject() {
        guard let project = app.project else {
            showHome()
            return
        }
        guard workspace?.project !== project, let window else { return }
        // Opening one project from another: the last one's panes let go, their sizes kept.
        workspace?.close()
        let workspace = WorkspaceController(app: app, project: project, size: window.contentLayoutRect.size)
        setContent(workspace)
        window.toolbar = workspace.toolbar.toolbar
        self.workspace = workspace
        home = nil
        titleWatch?.cancel()
        titleWatch = track({ [project] in OpenFile(path: project.openPath, url: project.openURL) }) { [weak self, project] file in
            guard let window = self?.window else { return }
            window.title = file.path.map { ($0 as NSString).lastPathComponent } ?? project.id
            window.subtitle = file.path == nil ? "" : project.id
            // The title's proxy icon: the file itself, to drag or Command-click.
            window.representedURL = file.url
        }
    }

    private func showHome() {
        guard home == nil || workspace != nil, let window else { return }
        titleWatch?.cancel()
        workspace?.close()
        workspace = nil
        window.toolbar = nil
        window.subtitle = ""
        window.representedURL = nil
        let home = NSHostingController(rootView: HomeRoot(app: app))
        // Its SwiftUI toolbar, search field and title become the window's.
        home.sceneBridgingOptions = [.title, .toolbars]
        setContent(home)
        self.home = home
    }

    /// Keeps the window's frame and minimum: a new content view controller sizes the
    /// window to its view and sets the minimum to zero.
    private func setContent(_ controller: NSViewController) {
        guard let window else { return }
        let frame = window.frame
        window.contentViewController = controller
        window.contentMinSize = WindowMetrics.contentMinimum
        window.setFrame(frame, display: true)
    }

    // ---------- window ----------

    func windowDidBecomeKey(_ notification: Notification) {
        app.mainWindowIsKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        app.mainWindowIsKey = false
    }

    /// The find bars' fields get the editor that passes Edit › Find's items on.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, workspace?.hostsFindField(field) == true else { return nil }
        return findEditor
    }

    /// Edit › Find's items, which the system sends down the responder chain with
    /// the `NSTextFinder.Action` as the item's tag, to the pane with the keyboard.
    /// Nothing before the window answers them: not the editor's plain web view,
    /// not PDFView, and the find fields pass them on (`FindFieldEditor`).
    @objc func performFindPanelAction(_ sender: Any?) {
        findAction(for: sender)?()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performFindPanelAction(_:)) else { return true }
        return findAction(for: item) != nil
    }

    private func findAction(for sender: Any?) -> (() -> Void)? {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return nil }
        return workspace?.findAction(action)
    }

    // ---------- restoration ----------

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        completionHandler(identifier == Self.identifier ? AppDelegate.shared?.mainWindow.window : nil, nil)
    }

    /// Where the project was left. Only with the window's state: with "Close windows
    /// when quitting an app" on, the next launch shows the projects.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        if let saved = app.project?.saved, let data = try? JSONEncoder().encode(saved) {
            state.encode(data as NSData, forKey: Self.workspaceKey)
        }
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        restored = (state.decodeObject(of: NSData.self, forKey: Self.workspaceKey) as Data?)
            .flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
    }

    private static let workspaceKey = "workspace"
}

/// The file the title names: renaming it moves the URL after the path.
private nonisolated struct OpenFile: Equatable {
    let path: String?
    let url: URL?
}

/// The projects screen, with the window's own sheets and alerts.
struct HomeRoot: View {
    let app: AppModel

    var body: some View {
        HomeView()
            .windowModals()
            .environment(app)
    }
}

/// Runs `apply` with `value()` now (unless `initial` is false), and again each time
/// something `value` read changes to give a different value, until the task is cancelled.
func track<Value: Sendable & Equatable>(_ value: @escaping @MainActor @Sendable () -> Value, initial: Bool = true,
                                          _ apply: @escaping @MainActor (Value) -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        var last: Value?
        var first = true
        for await next in Observations(value) {
            defer { first = false }
            if let last, last == next { continue }
            last = next
            if first, !initial { continue }
            apply(next)
        }
    }
}

enum WindowMetrics {
    /// The content's minimum, below the toolbar: every column at its own.
    static let contentMinimum = CGSize(width: ColumnMetrics.contentMinimumWidth, height: 548)
    /// Fits the smallest current Mac display's default resolution (1470 × 956)
    /// with the menu bar and Dock.
    static let projectDefault = CGSize(width: 1200, height: 760)
}
