import AppKit
import PDFKit
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let app: AppModel
    /// Made each time the projects show and let go when a project opens, so one screen's alerts and sheets never wait in another's views.
    private var home: NSHostingController<HomeRoot>?
    private(set) var workspace: WorkspaceController?
    private var restored: SavedWorkspace?
    private var watches: [Task<Void, Never>] = []
    private var titleWatch: Task<Void, Never>?
    private let findEditor = FindPassingTextView()

    init(app: AppModel) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.identifier = Self.identifier
        window.restorationClass = Self.self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.autorecalculatesKeyViewLoop = true
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
            track({ [app] in app.project?.saveFailure != nil }) { [weak self] in self?.window?.isDocumentEdited = $0 },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        showWindow(nil)
        guard Core.shared.isOpen else { return }
        Task {
            // Beside the listing, and before a project opens: its first build needs to know of TeX.
            async let tex: Void = app.refreshTeXStatus()
            await app.refresh()
            await tex
            let saved = restored.flatMap { saved in app.projects.contains { $0.id == saved.project } ? saved : nil }
            restored = nil
            if let id = app.takeLaunchProject() ?? saved?.project, app.project == nil, !app.isOpening {
                await app.open(id, restoring: saved)
            }
        }
    }

    // MARK: - Content

    private func showProject() {
        // Wait for the first outline so the workspace does not animate it in.
        guard let project = app.project, project.initialLoadComplete else { return showHome() }
        guard workspace?.project !== project, let window else { return }
        workspace?.close()
        let workspace = WorkspaceController(app: app, project: project, size: window.contentLayoutRect.size)
        setContent(workspace)
        window.contentMinSize = ColumnMetrics.contentMinimum
        // AppKit's top scroll edge is a glass that lightens what is under it in Dark (27.2), so the toolbar over the source is the editor's surface at rest only in Light.
        window.backgroundColor = .untintedTextBackground
        window.toolbar = workspace.toolbar.toolbar
        // Compile's form goes by the toolbar's tools, which a workspace that appeared as the window took it could not yet read.
        workspace.toolbarItemsChanged()
        self.workspace = workspace
        home = nil
        titleWatch?.cancel()
        titleWatch = track({ [project] in OpenFile(path: project.openPath, url: project.openURL) }) { [weak self, project] file in
            guard let window = self?.window else { return }
            window.title = file.path?.fileName ?? project.id
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
        window.backgroundColor = .windowBackgroundColor
        window.subtitle = ""
        window.representedURL = nil
        let home = NSHostingController(rootView: HomeRoot(app: app))
        home.sceneBridgingOptions = [.title, .toolbars]
        setContent(home)
        self.home = home
    }

    /// A new content view controller resets the window's frame.
    private func setContent(_ controller: NSViewController) {
        guard let window else { return }
        controller.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = controller
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) { app.mainWindowIsKey = true }
    func windowDidResignKey(_ notification: Notification) { app.mainWindowIsKey = false }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, workspace?.hostsFindField(field) == true else { return nil }
        return findEditor
    }

    @objc func performFindPanelAction(_ sender: Any?) { findAction(for: sender)?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(performFindPanelAction(_:)): findAction(for: item) != nil
        case #selector(centerSelectionInVisibleArea(_:)): workspace?.pdf.view.currentSelection?.pages.isEmpty == false
        default: true
        }
    }

    private func findAction(for sender: Any?) -> (() -> Void)? {
        (sender as? any NSValidatedUserInterfaceItem).flatMap { workspace?.findAction($0) }
    }

    override func centerSelectionInVisibleArea(_ sender: Any?) { workspace?.pdf.view.jumpToSelection() }

    /// Answered here only while the PDF's pages have the keyboard. Elsewhere it stays unanswered: its menu item is off, and its key
    /// binding (⌃L) falls off the responder chain, where NSResponder beeps (27.2) and a controller that always answered would take it in silence.
    override nonisolated func responds(to selector: Selector!) -> Bool {
        guard selector == #selector(centerSelectionInVisibleArea(_:)) else { return super.responds(to: selector) }
        // The responder chain asks on the main thread.
        return MainActor.assumeIsolated { workspace?.pdfPagesHaveKeyboard == true }
    }

    // MARK: - Restoration

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        completionHandler(identifier == Self.identifier ? AppDelegate.shared?.mainWindow.window : nil, nil)
    }

    /// Only with the window's state: with "Close windows when quitting an app" on, the next launch shows the projects.
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
    let path: String?, url: URL?
}

struct HomeRoot: View {
    let app: AppModel

    var body: some View {
        HomeView()
            // SwiftUI sets the window's minimum from its content's: the workspace's narrowest.
            .frame(minWidth: ColumnMetrics.contentMinimum.width, minHeight: ColumnMetrics.contentMinimum.height)
            .windowModals()
            .environment(app)
    }
}
