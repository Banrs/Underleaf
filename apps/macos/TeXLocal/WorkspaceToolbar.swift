import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let undo = Self("undo")
    static let redo = Self("redo")
    static let format = Self("sectionLevel")
    static let bold = Self("bold")
    static let italic = Self("italic")
    static let math = Self("math")
    static let insert = Self("insert")
    /// The source/PDF divider's line through the toolbar.
    static let pdfSeparator = Self("pdfSeparator")
    static let zoom = Self("zoom")
    static let share = Self("share")
    static let compile = Self("compile")
    static let togglePDF = Self("togglePDF")

    static func template(_ template: Template) -> Self { Self("template." + template.title) }
}

/// Pane-aligned tools, with PDF tools following the source/PDF divider and window toggles trailing.
/// Editing tools and Share overflow before Zoom; Compile and window toggles take priority.
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation {
    let toolbar = NSToolbar(identifier: "Workspace")
    private let app: AppModel
    private let project: ProjectModel
    private var pdf: PDFController { project.pdf }
    private weak var workspace: WorkspaceController?
    private var watch: Task<Void, Never>?

    init(app: AppModel, project: ProjectModel, workspace: WorkspaceController) {
        self.app = app
        self.project = project
        self.workspace = workspace
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        watch = track({ [weak self] in self?.state }) { [weak self] state in
            if let state { self?.apply(state) }
        }
    }

    func close() {
        watch?.cancel()
    }

    // ---------- items ----------

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .format, .math, .insert,
         .pdfSeparator, .zoom, .share, .flexibleSpace, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .togglePDF, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undo, .redo, .format, .bold, .italic, .math, .insert]
            + Self.buttonTemplates.map(NSToolbarItem.Identifier.template)
            + [.zoom, .share, .space, .flexibleSpace]
            + toolbarImmovableItemIdentifiers(toolbar)
    }

    private static let buttonTemplates = (referenceTemplates + insertTemplates + listTemplates).filter { $0.symbol != nil }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile, .togglePDF,
         .inspectorTrackingSeparator, .toggleInspector]
    }

    /// The system's toggles go to the window's split, not the nested ones, which would answer first.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              [.toggleSidebar, .toggleInspector].contains(item.itemIdentifier) else { return }
        item.target = workspace
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .back:
            item = button(id, "Projects", "chevron.backward", #selector(back), help: "Back to Projects")
            // Back leads the title; there is no forward history.
            item.isNavigational = true
        case .undo:
            item = button(id, "Undo", "arrow.uturn.backward", Selector(("undo:")))
            // Whatever has the keyboard, as the menu's Undo: it validates them too.
            item.target = nil
            item.visibilityPriority = .low
        case .redo:
            item = button(id, "Redo", "arrow.uturn.forward", Selector(("redo:")))
            item.target = nil
            item.visibilityPriority = .low
        case .format:
            item = formatItem()
        case .bold:
            item = button(id, MenuCommand.editBold.title, "bold", #selector(bold))
            item.visibilityPriority = .low
        case .italic:
            item = button(id, MenuCommand.editItalic.title, "italic", #selector(italic))
            item.visibilityPriority = .low
        case .math:
            item = menuItem(id, "Math", "radicand.squareroot",
                            NSHostingMenu(rootView: MathMenuItems(project: project, inlineMath: inlineMath)))
        case .insert:
            item = menuItem(id, "Insert", "plus", NSHostingMenu(rootView: InsertMenuItems(project: project)), indicator: true)
        case .pdfSeparator:
            guard let split = workspace?.columns.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case .zoom:
            item = zoomItem()
        case .share:
            let share = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            share.delegate = self
            share.toolTip = "Share PDF"
            share.visibilityPriority = .low
            item = share
        case .compile:
            // Xcode's Run and Stop: one symbol in its place, so the item keeps its width.
            item = button(id, MenuCommand.compileRun.title, "play.fill", #selector(compile))
            item.style = .prominent
            item.visibilityPriority = .high
        case .togglePDF:
            // A document's symbol: the PDF is the source's peer, not a sidebar or an inspector.
            item = button(id, "PDF", "richtext.page", #selector(togglePDF))
            item.visibilityPriority = .high
        default:
            guard let template = Self.buttonTemplates.first(where: { .template($0) == id }),
                  let symbolName = template.symbol else { return nil }
            item = button(id, template.title, symbolName, #selector(insertTemplate(_:)))
            item.visibilityPriority = .low
        }
        // Plain buttons and their overflow copies validate through their targets.
        // Other controls take their state from the models (`apply`).
        if (item.target !== self && ![.undo, .redo].contains(id)) || item.view != nil {
            item.autovalidates = false
        }
        if flag { configure(item, state) }
        return item
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbolName: String, _ action: Selector,
                        help: String? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = help ?? label
        item.image = symbol(symbolName, label)
        item.target = self
        item.action = action
        return item
    }

    /// Zoom out | scale menu | zoom in, one native capsule.
    private func zoomItem() -> NSToolbarItem {
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        form.image = symbol("plus.magnifyingglass", "Zoom")
        let menu = NSHostingMenu(rootView: Group { [app, project, pdf] in
            // The menu bar's items carry the shortcuts.
            ForEach([MenuCommand.viewZoomIn, .viewZoomOut], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
                    .disabled(!app.isEnabled(command, on: project))
            }
            Divider()
            ScaleMenuItems(pdf: pdf)
        })
        form.submenu = menu
        let control = NSSegmentedControl(images: [symbol("minus.magnifyingglass", "Zoom Out"), NSImage(),
                                                  symbol("plus.magnifyingglass", "Zoom In")].compactMap(\.self),
                                         trackingMode: .momentary, target: nil, action: nil)
        control.addTarget(self, action: #selector(zoom(_:)), for: .primaryActionTriggered)
        control.setImage(nil, forSegment: 1)
        control.setLabel(pdf.zoomLabel, forSegment: 1)
        control.setMenu(NSHostingMenu(rootView: ScaleMenuItems(pdf: pdf)), forSegment: 1)
        control.setShowsMenuIndicator(true, forSegment: 1)
        for (index, title) in ["Zoom Out", "Scale", "Zoom In"].enumerated() {
            control.setToolTip(title, forSegment: index)
        }
        control.setAccessibilityLabel("Zoom")
        let item = NSToolbarItem(itemIdentifier: .zoom)
        item.label = "Zoom"
        item.view = control
        item.menuFormRepresentation = form
        return item
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, _ title: String, _ image: String,
                          _ menu: NSMenu, indicator: Bool = false) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = title
        item.toolTip = title
        item.image = symbol(image, title)
        item.showsIndicator = indicator
        item.menu = menu
        item.visibilityPriority = .low
        return item
    }

    private func formatItem() -> NSToolbarItem {
        menuItem(.format, "Format", "textformat", NSHostingMenu(rootView: Group { [app, project] in
            ForEach([MenuCommand.editBold, .editItalic], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
            }
            Divider()
            SectionLevelItems(project: project)
        }))
    }

    /// Inline Math for the toolbar's menus; the menu bar's carries the shortcut.
    private var inlineMath: some View {
        Button(MenuCommand.editMath.title) { [app, project] in app.perform(.editMath, on: project) }
    }

    // ---------- state ----------

    private nonisolated struct State: Equatable {
        let isLaTeX: Bool
        let hasPDF: Bool
        let showsPDF: Bool
        let zoomLabel: String
        let canZoomIn: Bool
        let canZoomOut: Bool
        let compiling: Bool
        let pdfTitle: String
    }

    private var state: State {
        State(isLaTeX: project.isLaTeX,
              hasPDF: project.hasPDF, showsPDF: app.showPDF,
              zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
              compiling: project.compiling,
              pdfTitle: app.title(.viewTogglePdf, on: project))
    }

    private func apply(_ state: State) {
        for item in toolbar.items { configure(item, state) }
    }

    private func configure(_ item: NSToolbarItem, _ state: State) {
        switch item.itemIdentifier {
        case .format, .math, .insert:
            item.isEnabled = state.isLaTeX
        case .zoom:
            let control = item.view as? NSSegmentedControl
            // Reapply tabular digits during updates; otherwise Share shifts with the scale.
            if let font = control?.font { control?.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) }
            control?.setLabel(state.zoomLabel, forSegment: 1)
            control?.setEnabled(state.hasPDF && state.canZoomOut, forSegment: 0)
            control?.setEnabled(state.hasPDF, forSegment: 1)
            control?.setEnabled(state.hasPDF && state.canZoomIn, forSegment: 2)
            item.isEnabled = state.hasPDF
            item.isHidden = !state.showsPDF
        case .share:
            item.isEnabled = state.hasPDF
        case .compile:
            let command = state.compiling ? MenuCommand.compileStop : .compileRun
            item.label = command.title
            item.toolTip = command.title
            item.image = symbol(state.compiling ? "stop.fill" : "play.fill", command.title)
        case .togglePDF:
            item.toolTip = state.pdfTitle
        default:
            break
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .bold, .italic: project.isLaTeX
        case .compile: canCompile
        default: item.action != #selector(insertTemplate(_:)) || project.isLaTeX
        }
    }

    private var canCompile: Bool {
        project.compiling || app.isEnabled(.compileRun, on: project)
    }

    // ---------- actions ----------

    private func perform(_ command: MenuCommand) {
        app.perform(command, on: project)
    }

    @objc private func back() { perform(.projectClose) }

    @objc private func bold() { perform(.editBold) }

    @objc private func italic() { perform(.editItalic) }

    @objc private func insertTemplate(_ item: NSToolbarItem) {
        guard let template = Self.buttonTemplates.first(where: { .template($0) == item.itemIdentifier }) else { return }
        project.insert(template)
    }

    @objc private func zoom(_ control: NSSegmentedControl) {
        guard control.selectedSegment == 0 || control.selectedSegment == 2 else { return }
        pdf.zoom(in: control.selectedSegment == 2)
    }

    @objc private func compile() {
        perform(project.compiling ? .compileStop : .compileRun)
    }

    @objc private func togglePDF() { perform(.viewTogglePdf) }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        project.pdfURL.map { [$0] } ?? []
    }
}
