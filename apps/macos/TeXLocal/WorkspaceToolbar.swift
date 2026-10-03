import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let undo = Self("undo")
    static let redo = Self("redo")
    /// Format, Math and Insert in one capsule.
    static let formatMathInsert = Self("formatMathInsert")
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
    /// The PDF and Inspector toggles in one capsule.
    static let pdfInspector = Self("pdfInspector")
    static let togglePDF = Self("togglePDF")
    /// The app's own: the system's Inspector toggle draws blank inside a group (27.2).
    static let inspectorToggle = Self("inspectorToggle")

    static func template(_ template: Template) -> Self { Self("template." + template.title) }
}

/// Pane-aligned tools, with PDF tools following the source/PDF divider and window toggles trailing.
/// Related tools share a capsule, as Pages groups its own (HIG, Toolbars), and a group moves and
/// overflows as one. Editing tools overflow before Zoom; Compile and window toggles take priority.
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation, NSMenuItemValidation {
    /// Renamed with the groups: a layout saved under "Workspace" lists the separate items,
    /// which would come back ungrouped.
    let toolbar = NSToolbar(identifier: "Workspace 2")
    /// AppKit's menu indicators on Format, Math and Insert. With them, the group draws a
    /// capsule for each (27.2); without, one for all three, as Pages' insert tools.
    private static let menuIndicators = false
    private let app: AppModel
    private let project: ProjectModel
    private var pdf: PDFController { project.pdf }
    private weak var workspace: WorkspaceController?
    /// What the items show; `watch` sets only what differs from it.
    private var applied: State?
    private var closed = false

    init(app: AppModel, project: ProjectModel, workspace: WorkspaceController) {
        self.app = app
        self.project = project
        self.workspace = workspace
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        watch()
    }

    func close() {
        closed = true
    }

    // ---------- items ----------

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .formatMathInsert,
         .pdfSeparator, .zoom, .flexibleSpace, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .pdfInspector]
    }

    /// Share is here only: File › Share has it.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undo, .redo, .formatMathInsert, .bold, .italic]
            + Self.buttonTemplates.map(NSToolbarItem.Identifier.template)
            + [.zoom, .share, .space, .flexibleSpace]
            + toolbarImmovableItemIdentifiers(toolbar)
    }

    private static let buttonTemplates = (referenceTemplates + insertTemplates + listTemplates).filter { $0.symbol != nil }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile,
         .inspectorTrackingSeparator, .pdfInspector]
    }

    /// The system's toggle goes to the window's split, not the nested ones, which would answer first.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem, item.itemIdentifier == .toggleSidebar else { return }
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
        case .formatMathInsert:
            item = group(id, "Format/Math/Insert", [
                formatItem(),
                menuItem(.math, "Math", "radicand.squareroot", MathMenuItems(project: project, inlineMath: inlineMath)),
                menuItem(.insert, "Insert", "plus", InsertMenuItems(project: project)),
            ])
            item.visibilityPriority = .low
        case .bold:
            item = button(id, MenuCommand.editBold.title, "bold", #selector(bold))
            item.visibilityPriority = .low
        case .italic:
            item = button(id, MenuCommand.editItalic.title, "italic", #selector(italic))
            item.visibilityPriority = .low
        case .pdfSeparator:
            guard let split = workspace?.columns.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case .zoom:
            item = zoomItem()
        case .share:
            let share = ShareItem(itemIdentifier: id)
            share.delegate = self
            share.toolTip = "Share PDF"
            share.visibilityPriority = .low
            item = share
        case .compile:
            // The window's one prominent action (HIG Toolbars), titled: a play symbol alone reads as media.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            item.view = CompileButton(target: self, action: #selector(compile))
            // The labelled form too: sized for the longer of its two labels.
            item.possibleLabels = [MenuCommand.compileRun.title, MenuCommand.compileStop.title]
            let form = NSMenuItem(title: MenuCommand.compileRun.title, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
            item.style = .prominent
            item.visibilityPriority = .high
        case .pdfInspector:
            // A document's symbol: the PDF is the source's peer, not a sidebar or an inspector.
            let pdfToggle = button(.togglePDF, MenuCommand.viewTogglePdf.title, "richtext.page", #selector(togglePDF))
            // The system toggle's symbol and action, to the window's split.
            let inspectorToggle = button(.inspectorToggle, MenuCommand.viewToggleInspector.title, "sidebar.right",
                                         #selector(NSSplitViewController.toggleInspector(_:)))
            inspectorToggle.target = workspace
            item = group(id, "PDF/Inspector", [pdfToggle, inspectorToggle])
            item.visibilityPriority = .high
        default:
            guard let template = Self.buttonTemplates.first(where: { .template($0) == id }),
                  let symbolName = template.symbol else { return nil }
            item = button(id, template.title, symbolName, #selector(insertTemplate(_:)))
            item.visibilityPriority = .low
        }
        // Plain buttons and their overflow copies validate through their targets.
        // Other controls take their state from the models (`configure`).
        for item in Self.withSubitems(item)
        where (item.target !== self && ![.undo, .redo].contains(item.itemIdentifier)) || item.view != nil {
            item.autovalidates = false
        }
        if flag { Self.withSubitems(item).forEach { configure($0, state) } }
        return item
    }

    /// An item and, for a group, its items, which the toolbar doesn't list.
    private static func withSubitems(_ item: NSToolbarItem) -> [NSToolbarItem] {
        [item] + ((item as? NSToolbarItemGroup)?.subitems ?? [])
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
        let menu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.hasPDF }) { [app, project, pdf] in
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

    /// An editing menu, off with its items outside LaTeX (`configure`).
    private func menuItem(_ id: NSToolbarItem.Identifier, _ title: String, _ image: String,
                          _ items: some View) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = title
        item.toolTip = title
        item.image = symbol(image, title)
        item.menu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.isLaTeX }) { items })
        item.showsIndicator = Self.menuIndicators
        return item
    }

    private func formatItem() -> NSToolbarItem {
        menuItem(.format, "Format", "textformat", Group { [app, project] in
            ForEach([MenuCommand.editBold, .editItalic], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
            }
            Divider()
            SectionLevelItems(project: project)
        })
    }

    /// One capsule for its items. Unlabelled, it shows their labels, and the overflow menu
    /// lists their menus at its top level; a group's label would nest them a menu down.
    private func group(_ id: NSToolbarItem.Identifier, _ paletteLabel: String,
                       _ items: [NSToolbarItem]) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = items
        group.paletteLabel = paletteLabel
        return group
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
        let canCompile: Bool
        let pdfTitle: String
        let inspectorTitle: String
    }

    private var state: State {
        State(isLaTeX: project.isLaTeX,
              hasPDF: project.hasPDF, showsPDF: app.showPDF,
              zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
              compiling: project.compiling, canCompile: canCompile,
              pdfTitle: app.title(.viewTogglePdf, on: project),
              inspectorTitle: app.title(.viewToggleInspector, on: project))
    }

    /// Applies the state as it changes, in the same pass. A column resizing refits the PDF
    /// during layout, and an async `track` would set the new scale a pass later: the toolbar
    /// would draw each frame of a sidebar's animation twice, laid out, then relabelled.
    private func watch() {
        guard !closed else { return }
        let state = withObservationTracking(options: .didSet) { state } onChange: { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        guard state != applied else { return }
        for item in toolbar.items.flatMap(Self.withSubitems) { configure(item, state, from: applied) }
        applied = state
    }

    /// What changed since `old`, or all of it for a new item: an unchanged segment label
    /// still lays the toolbar out again.
    private func configure(_ item: NSToolbarItem, _ state: State, from old: State? = nil) {
        func changed<Value: Equatable>(_ field: KeyPath<State, Value>) -> Bool {
            old?[keyPath: field] != state[keyPath: field]
        }
        switch item.itemIdentifier {
        case .format, .math, .insert:
            if changed(\.isLaTeX) { item.isEnabled = state.isLaTeX }
        case .zoom:
            let control = item.view as? NSSegmentedControl
            if changed(\.zoomLabel) {
                // Reapply tabular digits during updates; otherwise Share shifts with the scale.
                if let font = control?.font { control?.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) }
                control?.setLabel(state.zoomLabel, forSegment: 1)
            }
            if changed(\.hasPDF) || changed(\.canZoomOut) { control?.setEnabled(state.hasPDF && state.canZoomOut, forSegment: 0) }
            if changed(\.hasPDF) {
                control?.setEnabled(state.hasPDF, forSegment: 1)
                item.isEnabled = state.hasPDF
            }
            if changed(\.hasPDF) || changed(\.canZoomIn) { control?.setEnabled(state.hasPDF && state.canZoomIn, forSegment: 2) }
            if changed(\.showsPDF) { item.isHidden = !state.showsPDF }
        case .share:
            if changed(\.hasPDF) { item.isEnabled = state.hasPDF }
        case .compile:
            if changed(\.compiling) {
                let command = state.compiling ? MenuCommand.compileStop : .compileRun
                item.label = command.title
                item.toolTip = command.title
                item.menuFormRepresentation?.title = command.title
                (item.view as? CompileButton)?.compiling = state.compiling
            }
            if changed(\.canCompile) { item.isEnabled = state.canCompile }
        case .togglePDF:
            if changed(\.pdfTitle) { item.toolTip = state.pdfTitle }
        case .inspectorToggle:
            if changed(\.inspectorTitle) { item.toolTip = state.inspectorTitle }
        default:
            break
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .bold, .italic: project.isLaTeX
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

    /// The overflow menu's Compile, which the item's own view doesn't enable.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(compile) || canCompile
    }

    @objc private func togglePDF() { perform(.viewTogglePdf) }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        project.pdfURL.map { [$0] } ?? []
    }
}

/// Share, off in the overflow menu as in the toolbar: the menu asks the item, and AppKit's
/// answer for it ignores `isEnabled` (27.2).
private final class ShareItem: NSSharingServicePickerToolbarItem {
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled && super.validateMenuItem(menuItem)
    }
}

/// A toolbar menu's items, off while its item is: the overflow menu still opens the menu,
/// which stays available with its items dimmed (HIG, Menus).
private struct ToolbarMenuItems<Content: View>: View {
    let isEnabled: () -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().disabled(!isEnabled())
    }
}

/// Compile's button in the item's place, drawn as the toolbar draws its own (title and
/// symbol on the item's prominent glass). Stop shows the stock spinner in the symbol's
/// place and keeps Compile's width, so the toolbar doesn't shift as a build starts.
private final class CompileButton: NSButton {
    private static let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)!
    private let spinner = NSProgressIndicator()
    private var compileWidth: CGFloat = 0

    convenience init(target: AnyObject, action: Selector) {
        self.init(title: MenuCommand.compileRun.title, image: Self.play, target: target, action: action)
        bezelStyle = .toolbar
        imagePosition = .imageLeading
        // Stop's shorter title keeps the spinner beside it in Compile's width.
        imageHugsTitle = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        // Light, as the title on the tinted glass in either appearance.
        spinner.appearance = NSAppearance(named: .darkAqua)
        // The button's title says Stop; the status bar says Compiling.
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
    }

    var compiling = false {
        didSet {
            guard compiling != oldValue else { return }
            title = compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title
            // A blank of the symbol's size keeps the title where the spinner leaves it.
            image = compiling ? NSImage(size: Self.play.size) : Self.play
            if compiling { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            needsLayout = true
        }
    }

    /// Compile's width as the toolbar lays it out, which is wider than outside it.
    /// The toolbar sizes the item's glass from this, not from constraints.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if compiling { size.width = max(size.width, compileWidth) } else { compileWidth = size.width }
        return size
    }

    override func layout() {
        super.layout()
        guard let place = cell?.imageRect(forBounds: bounds) else { return }
        let size = spinner.fittingSize
        spinner.frame = NSRect(x: place.midX - size.width / 2, y: place.midY - size.height / 2,
                               width: size.width, height: size.height)
    }
}
