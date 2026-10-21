import AppKit
import PDFKit
import SwiftUI

/// The one main window: Home, or the open project's workspace once it has loaded (`AppModel.workspaceProject`).
final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let app: AppModel
    /// Made each time the projects show, so one screen's alerts and sheets never wait in another's views.
    private var home: NSViewController?
    private(set) var workspace: WorkspaceController?
    private let modals: NSHostingView<WindowModals>
    private var restored: SavedWorkspace?
    private var watches: [Task<Void, Never>] = []
    private var titleWatch: Task<Void, Never>?
    private let findEditor = FindPassingTextView()

    init(app: AppModel) {
        self.app = app
        modals = NSHostingView(rootView: WindowModals(app: app, project: nil))
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
        modals.sizingOptions = []
        findEditor.isFieldEditor = true
        showHome()
        window.center()
        // After centring: a frame saved by an earlier launch wins.
        window.setFrameAutosaveName("Main Window")
        watches = [
            track({ [app, weak self] in app.workspaceProject(after: self?.workspace?.project).map { ObjectIdentifier($0) } }) {
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
            if let id = app.launchProject.take() ?? saved?.project, app.project == nil, !app.isOpening {
                await app.open(id, restoring: saved)
            }
        }
    }

    // MARK: - Content

    private func showProject() {
        guard let project = app.workspaceProject(after: workspace?.project) else { return showHome() }
        guard workspace?.project !== project, let window else { return }
        workspace?.close()
        let workspace = WorkspaceController(app: app, project: project, size: window.contentLayoutRect.size)
        setContent(workspace, project: project)
        window.contentMinSize = ColumnMetrics.contentMinimum
        // The toolbar's ground over the source is the editor's surface.
        window.backgroundColor = .untintedTextBackground
        window.toolbar = workspace.toolbar.toolbar
        // Compile's form goes by the toolbar's tools, which the workspace could not read before the window had them.
        workspace.toolbarItemsChanged()
        self.workspace = workspace
        home = nil
        titleWatch?.cancel()
        titleWatch = track({ [project] in project.openPath }) { [weak self, project] path in
            guard let window = self?.window else { return }
            window.title = path?.fileName ?? project.id
            window.subtitle = path == nil ? "" : project.id
            window.representedURL = path.flatMap { project.url($0) }
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
        // SwiftUI sets the window's minimum from its content's: the workspace's narrowest.
        let home = NSHostingController(rootView: HomeView()
            .frame(minWidth: ColumnMetrics.contentMinimum.width, minHeight: ColumnMetrics.contentMinimum.height)
            .environment(app))
        home.sceneBridgingOptions = [.title, .toolbars]
        setContent(home, project: nil)
        self.home = home
    }

    /// A new content view controller would reset the window's frame.
    private func setContent(_ controller: NSViewController, project: ProjectModel?) {
        guard let window else { return }
        controller.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = controller
        modals.rootView = WindowModals(app: app, project: project)
        controller.view.addSubview(modals)
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) { app.mainWindowIsKey = true }
    func windowDidResignKey(_ notification: Notification) { app.mainWindowIsKey = false }

    // MARK: - Find

    /// The PDF find bar's field passes Find on to here (`FindPassingTextView`).
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, field === workspace?.pdf.find.field.field else { return nil }
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

    /// ⌘F, ⌘G and ⌘E go to the editor or to the PDF, by which has the keyboard. On Home ⌘F is its search field's, as
    /// Finder's and Music's.
    private func findAction(for sender: Any?) -> (() -> Void)? {
        guard let item = sender as? any NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag)
        else { return nil }
        let app = app
        guard let project = workspace?.project, !project.closed else {
            guard home != nil, action == .showFindInterface else { return nil }
            return { app.searchFocusToken += 1 }
        }
        let pdf = project.pdf
        guard app.showPDF, pdfPagesHaveKeyboard || pdf.find.field.hasFocus else {
            guard project.editsText else {
                guard action == .showFindInterface, project.hasPDF else { return nil }
                return { app.requestPDF(.find) }
            }
            let editor = project.editor
            guard editor.textView.validateUserInterfaceItem(item) else { return nil }
            return {
                editor.focus()
                editor.textView.performFindPanelAction(item)
            }
        }
        guard project.hasPDF else { return nil }
        switch action {
        case .showFindInterface:
            return { app.requestPDF(.find) }
        case .nextMatch, .previousMatch:
            guard pdf.find.canNext else { return nil }
            return { pdf.find.next(action == .nextMatch ? 1 : -1) }
        case .setSearchString:
            guard pdf.find.canUseSelection else { return nil }
            return { pdf.find.useSelection() }
        default:
            return nil
        }
    }

    private var pdfPagesHaveKeyboard: Bool {
        guard let pdf = workspace?.pdf else { return false }
        return (window?.firstResponder as? NSView)?.isDescendant(of: pdf.view) == true
    }

    override func centerSelectionInVisibleArea(_ sender: Any?) { workspace?.pdf.view.jumpToSelection() }

    /// Only while the PDF's pages have the keyboard: elsewhere ⌃L falls off the responder chain, which beeps, where a
    /// controller that always answered would take it in silence. The responder chain asks on the main thread.
    override nonisolated func responds(to selector: Selector!) -> Bool {
        guard selector == #selector(centerSelectionInVisibleArea(_:)) else { return super.responds(to: selector) }
        return MainActor.assumeIsolated { pdfPagesHaveKeyboard }
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

private struct WindowModals: View {
    let app: AppModel
    let project: ProjectModel?

    var body: some View {
        @Bindable var app = app
        Group {
            if let project { Color.clear.modifier(WorkspaceModals(project: project)) } else { Color.clear }
        }
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
        .environment(app)
    }
}

extension View {
    func alert(_ alert: Binding<AppAlert?>) -> some View {
        // No actions: the system adds its own OK.
        self.alert(alert.wrappedValue?.title ?? "", item: alert) { _ in } message: { alert in
            Text(alert.message)
        }
    }
}
