import AppKit
import PDFKit
import SwiftUI

/// What the Projects window and a project’s window share: a model told when it is main, and a controller kept while the window is open.
class AppWindowController: NSWindowController, NSWindowDelegate, AppWindow {
    private static var kept: [AppWindowController] = []
    let model: WindowModel

    init(model: WindowModel, size: NSSize) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        model.controller = self
        Self.kept.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { window?.undoManager }
    func show() { showWindow(nil) }
    func performPDF(_ action: PDFAction) {}
    func revealSidebar() {}
    func focusSearch() {}

    func windowDidBecomeMain(_ notification: Notification) { model.isMain = true }
    func windowDidResignMain(_ notification: Notification) { model.isMain = false }

    func windowWillClose(_ notification: Notification) {
        model.isMain = false
        model.windowClosed()
        closed()
        Self.kept.removeAll { $0 === self }
    }

    func closed() {}
}

final class MainWindowController: AppWindowController, NSWindowRestoration, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let views: WorkspaceViews
    private var project: ProjectModel { views.project }
    private(set) var workspace: WorkspaceController?
    private var watches: [Task<Void, Never>] = []
    private var framed = false

    init(app: AppModel, project id: String) {
        let model = WindowModel(app: app, project: id)
        let views = WorkspaceViews(project: ProjectModel(id: id, window: model))
        model.project = views.project
        self.views = views
        super.init(model: model, size: NSSize(width: 1200, height: 760))
        let window = self.window!
        window.identifier = Self.identifier
        window.restorationClass = Self.self
        window.autorecalculatesKeyViewLoop = true
        window.contentMinSize = ColumnMetrics.contentMinimum
        window.backgroundColor = .untintedTextBackground
        let frameName = "Project \(id)"
        framed = window.setFrameUsingName(frameName)
        if !framed { window.center() }
        window.setFrameAutosaveName(frameName)
        let project = views.project
        showWorkspace(in: window)
        watches = [
            track({ project.store.project?.name ?? "" }) { [weak self] in self?.window?.title = $0 },
            track({ project.openPath?.fileName ?? "" }) { [weak self] in self?.window?.subtitle = $0 },
            track({ project.url("") }) { [weak self] in self?.window?.representedURL = $0 },
            track({ project.saveFailure != nil }) { [weak self] in self?.window?.isDocumentEdited = $0 },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func show() {
        if !framed, let window, !window.isVisible, !window.isMiniaturized,
           let front = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible && $0.windowController is MainWindowController }) {
            window.setFrame(front.cascadingReferenceFrame, display: false)
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: .zero))
        }
        showWindow(nil)
    }

    override func performPDF(_ action: PDFAction) { workspace?.performPDF(action) }
    override func revealSidebar() { workspace?.revealSidebar() }
    override func focusSearch() { workspace?.focusSearch() }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        guard action == #selector(NSSplitViewController.toggleInspector(_:)) else { return super.supplementalTarget(forAction: action, sender: sender) }
        return window?.contentViewController as? WorkspaceController
    }

    private func showWorkspace(in window: NSWindow) {
        let workspace = WorkspaceController(window: model, views: views, size: window.contentLayoutRect.size)
        workspace.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        let modals = NSHostingView(rootView: WindowModals(window: model, project: project).environment(views))
        modals.sizingOptions = []
        workspace.view.addSubview(modals)
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        self.workspace = workspace
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.shownProject != nil else { return true }
        Task { await model.close() }
        return false
    }

    override func closed() {
        watches.forEach { $0.cancel() }
        workspace?.close()
    }

    @objc func performFindPanelAction(_ sender: Any?) { findAction(for: sender)?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(performFindPanelAction(_:)) || findAction(for: item) != nil
    }

    private func findAction(for sender: Any?) -> (() -> Void)? {
        guard let item = sender as? any NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag),
              workspace != nil, !project.closed else { return nil }
        let (model, editor, find) = (model, views.editor, views.pdf.view.find)
        if model.showPDF, !model.showSource { return find.validate(action) ? { find.perform(action) } : nil }
        guard project.editsText else {
            guard action == .showFindInterface, project.hasPDF else { return nil }
            return { model.requestPDF(.find) }
        }
        guard editor.textView.validateUserInterfaceItem(item) else { return nil }
        return {
            editor.focus()
            editor.textView.performFindPanelAction(item)
        }
    }

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        guard identifier == Self.identifier, let app = AppDelegate.shared?.app,
              let id = state.decodeObject(of: NSString.self, forKey: projectKey) as String? else { return completionHandler(nil, nil) }
        completionHandler(MainWindowController(app: app, project: id).window, nil)
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        state.encode(project.id as NSString, forKey: Self.projectKey)
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
