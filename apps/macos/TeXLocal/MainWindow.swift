import AppKit
import PDFKit
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let app: AppModel
    private var home: NSViewController?
    private(set) var workspace: WorkspaceController?
    private var restored: String?
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
        window.setFrameAutosaveName("Main Window")
        watches = [
            track({ [app, weak self] in app.workspaceProject(after: self?.workspace?.project).map { ObjectIdentifier($0) } }) {
                [weak self] _ in self?.showProject()
            },
            track({ [app] in app.project?.id }) { [weak self] _ in self?.window?.invalidateRestorableState() },
            track({ [app] in app.project?.saveFailure != nil }) { [weak self] in self?.window?.isDocumentEdited = $0 },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        showWindow(nil)
        guard Core.shared.isOpen else { return }
        Task {
            async let tex: Void = app.refreshTeXStatus()
            await app.reloadProjects()
            await tex
            let restored = self.restored.take().flatMap { id in app.projects.contains { $0.id == id } ? id : nil }
            if let id = app.launchProject.take() ?? restored, app.project == nil, !app.isOpening { await app.open(id) }
        }
    }

    private func showProject() {
        guard let project = app.workspaceProject(after: workspace?.project) else { return showHome() }
        guard workspace?.project !== project, let window else { return }
        workspace?.close()
        let workspace = WorkspaceController(app: app, project: project, size: window.contentLayoutRect.size)
        window.toolbar = nil
        setContent(workspace)
        window.toolbar = workspace.toolbar.toolbar
        window.contentMinSize = ColumnMetrics.contentMinimum
        window.backgroundColor = .untintedTextBackground
        self.workspace = workspace
        home = nil
        titleWatch?.cancel()
        titleWatch = track({ [project] in project.openPath }) { [weak self, project] path in
            guard let window = self?.window else { return }
            window.title = path?.fileName ?? project.name
            window.subtitle = path == nil ? "" : project.name
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
        let home = NSHostingController(rootView: HomeView()
            .frame(minWidth: ColumnMetrics.contentMinimum.width, minHeight: ColumnMetrics.contentMinimum.height)
            .environment(app)
            .background { WindowModals(app: app, project: nil) })
        home.sceneBridgingOptions = [.title, .toolbars]
        setContent(home)
        self.home = home
    }

    private func setContent(_ controller: NSViewController) {
        guard let window else { return }
        controller.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = controller
    }

    func windowDidBecomeKey(_ notification: Notification) { app.mainWindowIsKey = true }
    func windowDidResignKey(_ notification: Notification) { app.mainWindowIsKey = false }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, field === workspace?.pdf.find.field.field else { return nil }
        return findEditor
    }

    @objc func performFindPanelAction(_ sender: Any?) { findAction(for: sender)?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(performFindPanelAction(_:)) || findAction(for: item) != nil
    }

    private func findAction(for sender: Any?) -> (() -> Void)? {
        guard let item = sender as? any NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag)
        else { return nil }
        let app = app
        guard let project = workspace?.project, !project.closed else {
            guard home != nil, action == .showFindInterface else { return nil }
            return { app.searchFocusToken += 1 }
        }
        let pdf = project.pdf
        guard app.showPDF, !app.showSource || pdfPagesHaveKeyboard || pdf.find.field.hasFocus else {
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

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        completionHandler(identifier == Self.identifier ? AppDelegate.shared?.mainWindow.window : nil, nil)
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        if let id = app.project?.id { state.encode(id as NSString, forKey: Self.projectKey) }
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        restored = state.decodeObject(of: NSString.self, forKey: Self.projectKey) as String?
    }

    private static let projectKey = "project"
}

struct WindowModals: View {
    let app: AppModel
    let project: ProjectModel?

    var body: some View {
        @Bindable var app = app
        Group {
            if let project { Color.clear.modifier(WorkspaceModals(project: project)) } else { Color.clear }
        }
        .background {
            Color.clear
                .fileImporter(isPresented: $app.openingProject, allowedContentTypes: AppModel.openableTypes) { result in
                    switch result {
                    case .success(let url): Task { await app.open(url) }
                    case .failure(let error): app.alert = AppAlert("Couldn’t Open the Project", error)
                    }
                }
                .fileDialogConfirmationLabel("Open")
                .fileDialogMessage("A folder, or a .tex file’s folder, opens where it is. A .zip is copied into the projects folder.")
        }
        .sheet(item: $app.newProjectDraft) { NewProjectSheet(draft: $0) }
        .alert($app.alert)
        .environment(app)
    }
}

extension View {
    func alert(_ alert: Binding<AppAlert?>) -> some View {
        self.alert(alert.wrappedValue?.title ?? "", item: alert) { _ in } message: { alert in
            Text(alert.message)
        }
    }
}
