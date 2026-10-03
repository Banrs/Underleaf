import AppKit
import SwiftUI

/// One AppKit window for the SwiftUI projects screen, native project split and
/// toolbar, and SwiftUI pane content.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let app: AppModel
    /// Made each time the projects show and let go when a project opens, so one
    /// screen's alerts and sheets never wait in another's views.
    private var home: NSHostingController<HomeRoot>?
    private(set) var workspace: WorkspaceController?
    private var restored: SavedWorkspace?
    private var watches: [Task<Void, Never>] = []
    private var titleWatch: Task<Void, Never>?
    /// Polls for TeX while it's missing; one at a time.
    private var texWatch: Task<Void, Never>?
    private let findEditor = FindPassingTextView()

    init(app: AppModel) {
        self.app = app
        // Fits the smallest current Mac display's default resolution (1470 × 956) with the menu bar and Dock.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
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
        findEditor.isFieldEditor = true
        showHome()
        window.center()
        // After centring: a frame saved by an earlier launch wins.
        window.setFrameAutosaveName("Main Window")
        watches = [
            track({ [app] in app.project.flatMap { $0.initialLoadComplete ? ObjectIdentifier($0) : nil } }) {
                [weak self] _ in self?.showProject()
            },
            track({ [app] in app.project?.saved }) { [weak self] _ in self?.window?.invalidateRestorableState() },
            // Installing TeX takes effect without a restart, whichever screen shows.
            track({ [app] in app.tex?.available }) { [weak self, app] available in
                self?.texWatch?.cancel()
                self?.texWatch = available == false ? Task { await app.watchForTeX() } : nil
            },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens the launch project or restored project after loading the library.
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

    private func showProject() {
        // Wait for the first outline so the workspace does not animate it in.
        guard let project = app.project, project.initialLoadComplete else {
            showHome()
            return
        }
        guard workspace?.project !== project, let window else { return }
        // Let the previous workspace release its panes and keep their sizes.
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

    /// Keeps the window's frame and minimum, which a new content view controller resets.
    private func setContent(_ controller: NSViewController) {
        guard let window else { return }
        controller.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = controller
        window.contentMinSize = ColumnMetrics.contentMinimum
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

    /// Route Edit › Find by action tag to the pane with the keyboard.
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

private nonisolated struct OpenFile: Equatable {
    let path: String?
    let url: URL?
}

struct HomeRoot: View {
    let app: AppModel

    var body: some View {
        HomeView()
            // SwiftUI sets the window's minimum from its content's: the app's own.
            .frame(minWidth: ColumnMetrics.contentMinimum.width, minHeight: ColumnMetrics.contentMinimum.height)
            .windowModals()
            .environment(app)
    }
}

/// Applies distinct observed values until cancelled, including the first unless disabled.
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
