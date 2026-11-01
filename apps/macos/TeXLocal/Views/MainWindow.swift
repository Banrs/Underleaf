import AppKit
import PDFKit
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, NSMenuItemValidation, AppWindow {
    static let identifier = NSUserInterfaceItemIdentifier("main")
    private static var kept: [MainWindowController] = []

    let model: WindowModel
    private let views: WorkspaceViews
    private var project: ProjectModel { views.project }
    private(set) var workspace: WorkspaceController?
    private var watches: [Task<Void, Never>] = []
    private let findEditor = FindPassingTextView()
    /// The window took the frame its project was last shown in, so it isn't cascaded from the front window.
    private let framed: Bool

    init(app: AppModel, project id: String) {
        let model = WindowModel(app: app)
        let views = WorkspaceViews(project: ProjectModel(id: id, window: model))
        model.project = views.project
        (self.model, self.views) = (model, views)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.identifier = Self.identifier
        window.restorationClass = Self.self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.autorecalculatesKeyViewLoop = true
        window.contentMinSize = ColumnMetrics.contentMinimum
        window.backgroundColor = .untintedTextBackground
        // Each project keeps its own frame; the names are unique per project, so no two open windows share one.
        let frameName = "Project \(id)"
        framed = window.setFrameUsingName(frameName)
        if !framed { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
        window.delegate = self
        model.controller = self
        Self.kept.append(self)
        findEditor.isFieldEditor = true
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

    func show() {
        if !framed, let window, !window.isVisible, !window.isMiniaturized,
           let front = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible && $0.windowController is MainWindowController }) {
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        }
        showWindow(nil)
    }

    override var undoManager: UndoManager? { window?.undoManager }
    func performPDF(_ action: PDFAction) { workspace?.performPDF(action) }
    func revealSidebar() { workspace?.revealSidebar() }
    func focusSearch() { workspace?.focusSearch() }

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

    func windowDidBecomeKey(_ notification: Notification) { model.isKey = true }
    func windowDidResignKey(_ notification: Notification) { model.isKey = false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.shownProject != nil else { return true }
        Task { await model.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.isKey = false
        model.windowClosed()
        watches.forEach { $0.cancel() }
        workspace?.close()
        Self.kept.removeAll { $0 === self }
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, field === views.pdf.find.field.field else { return nil }
        return findEditor
    }

    @objc func performFindPanelAction(_ sender: Any?) { findAction(for: sender)?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(performFindPanelAction(_:)) || findAction(for: item) != nil
    }

    private func findAction(for sender: Any?) -> (() -> Void)? {
        guard let item = sender as? any NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag),
              workspace != nil, !project.closed else { return nil }
        let (model, project, pdf) = (model, project, views.pdf)
        guard model.showPDF, !model.showSource || pdfPagesHaveKeyboard || pdf.find.field.hasFocus else {
            guard project.editsText else {
                guard action == .showFindInterface, project.hasPDF else { return nil }
                return { model.requestPDF(.find) }
            }
            let editor = views.editor
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

    private var pdfPagesHaveKeyboard: Bool { (window?.firstResponder as? NSView)?.isDescendant(of: views.pdf.view) == true }

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
