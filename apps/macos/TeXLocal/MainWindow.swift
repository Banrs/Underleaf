import AppKit
import PDFKit
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation, AppWindow {
    static let identifier = NSUserInterfaceItemIdentifier("main")
    private static var kept: [MainWindowController] = []

    let model: WindowModel
    private var app: AppModel { model.app }
    private var home: NSViewController?
    private(set) var workspace: WorkspaceController?
    private var views: WorkspaceViews?
    private var watches: [Task<Void, Never>] = []
    private var titleWatch: Task<Void, Never>?
    private let findEditor = FindPassingTextView()

    init(app: AppModel) {
        model = WindowModel(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.identifier = Self.identifier
        window.restorationClass = Self.self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "TeXLocal"
        window.toolbarStyle = .unified
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        model.controller = self
        Self.kept.append(self)
        findEditor.isFieldEditor = true
        showHome()
        window.center()
        window.setFrameAutosaveName("Main Window")
        let model = model
        watches = [
            track({ [model, weak self] in model.workspaceProject(after: self?.workspace?.project).map { ObjectIdentifier($0) } }) {
                [weak self] _ in self?.showProject()
            },
            track({ [model] in model.project?.id }) { [weak self] _ in self?.window?.invalidateRestorableState() },
            track({ [model] in model.project?.saveFailure != nil }) { [weak self] in self?.window?.isDocumentEdited = $0 },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    static func tab(app: AppModel, beside: WindowModel?) -> MainWindowController {
        let controller = MainWindowController(app: app)
        if let window = controller.window, let group = (beside?.controller as? MainWindowController)?.window {
            window.tabbingIdentifier = group.tabbingIdentifier
            group.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        return controller
    }

    override func newWindowForTab(_ sender: Any?) { Self.tab(app: app, beside: model) }

    func show() { showWindow(nil) }

    override var undoManager: UndoManager? { window?.undoManager }
    func attach(_ project: ProjectModel) { views = WorkspaceViews(project: project) }
    func performPDF(_ action: PDFAction) { workspace?.performPDF(action) }
    func revealSidebar() { workspace?.revealSidebar() }

    func focusSearch() {
        if let workspace { return workspace.focusSearch() }
        window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        guard action == #selector(NSSplitViewController.toggleInspector(_:)) else { return super.supplementalTarget(forAction: action, sender: sender) }
        return window?.contentViewController as? WorkspaceController
    }

    private func showProject() {
        guard let project = model.workspaceProject(after: workspace?.project) else { return showHome() }
        guard workspace?.project !== project, let views, views.project === project, let window else { return }
        workspace?.close()
        let workspace = WorkspaceController(window: model, views: views, size: window.contentLayoutRect.size)
        window.toolbar = nil
        setContent(workspace, project: project)
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
            window.tab.title = project.name
        }
    }

    private func showHome() {
        if model.project == nil { views = nil }
        guard home == nil || workspace != nil, let window else { return }
        titleWatch?.cancel()
        workspace?.close()
        workspace = nil
        window.toolbar = nil
        window.backgroundColor = .windowBackgroundColor
        window.subtitle = ""
        window.representedURL = nil
        window.tab.title = nil
        let home = NSHostingController(rootView: HomeView()
            .frame(minWidth: ColumnMetrics.contentMinimum.width, minHeight: ColumnMetrics.contentMinimum.height)
            .environment(app)
            .environment(model))
        home.sceneBridgingOptions = [.title, .toolbars]
        setContent(home, project: nil)
        self.home = home
    }

    private func setContent(_ controller: NSViewController, project: ProjectModel?) {
        guard let window else { return }
        controller.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        let modals = NSHostingView(rootView: WindowModals(window: model, project: project).environment(views))
        modals.sizingOptions = []
        controller.view.addSubview(modals)
        window.contentViewController = controller
    }

    func windowDidBecomeKey(_ notification: Notification) { model.isKey = true }
    func windowDidResignKey(_ notification: Notification) { model.isKey = false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.project?.isOpen == true || model.isOpening else { return true }
        Task { if await model.end() { sender.close() } }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.isKey = false
        model.windowClosed()
        watches.forEach { $0.cancel() }
        titleWatch?.cancel()
        workspace?.close()
        Self.kept.removeAll { $0 === self }
    }

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
        guard let workspace, !workspace.project.closed else {
            guard home != nil, action == .showFindInterface else { return nil }
            return { [weak self] in self?.focusSearch() }
        }
        let model = model
        let (project, pdf) = (workspace.project, workspace.pdf)
        guard model.showPDF, !model.showSource || pdfPagesHaveKeyboard || pdf.find.field.hasFocus else {
            guard project.editsText else {
                guard action == .showFindInterface, project.hasPDF else { return nil }
                return { model.requestPDF(.find) }
            }
            let editor = workspace.views.editor
            guard editor.textView.validateUserInterfaceItem(item) else { return nil }
            return {
                editor.focus()
                editor.textView.performFindPanelAction(item)
            }
        }
        guard project.hasPDF else { return nil }
        switch action {
        case .showFindInterface:
            return { model.requestPDF(.find) }
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
        let app = identifier == Self.identifier ? AppDelegate.shared?.app : nil
        completionHandler(app.flatMap { MainWindowController(app: $0).window }, nil)
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        if let id = model.project?.id { state.encode(id as NSString, forKey: Self.projectKey) }
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        model.restored = state.decodeObject(of: NSString.self, forKey: Self.projectKey) as String?
    }

    private static let projectKey = "project"
}

struct WindowModals: View {
    let window: WindowModel
    let project: ProjectModel?

    var body: some View {
        @Bindable var window = window
        Group {
            if let project { Color.clear.modifier(WorkspaceModals(project: project)) } else { Color.clear }
        }
        .background {
            Color.clear
                .fileImporter(isPresented: $window.openingProject, allowedContentTypes: AppModel.openableTypes) { result in
                    switch result {
                    case .success(let url): Task { await window.open(url) }
                    case .failure(let error): window.report("Couldn’t Open the Project", error)
                    }
                }
                .fileDialogConfirmationLabel("Open")
                .fileDialogMessage("A folder, or a .tex file’s folder, opens where it is. A .zip is copied into the projects folder.")
        }
        .sheet(item: $window.newProjectDraft) { NewProjectSheet(draft: $0) }
        .alert(window.alert?.title ?? "", item: $window.alert) { _ in } message: { Text($0.message) }
        .environment(window.app)
        .environment(window)
    }
}
