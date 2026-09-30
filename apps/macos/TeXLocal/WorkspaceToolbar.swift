import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let undo = Self("undo")
    static let redo = Self("redo")
    static let sectionLevel = Self("sectionLevel")
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

    /// A template's own button, for Customize Toolbar.
    static func template(_ template: Template) -> Self { Self("template." + template.title) }
}

/// The project window's toolbar, AppKit's so each column's tools sit over it: the PDF's
/// section starts at the source/PDF divider (`NSTrackingSeparatorToolbarItem`), and the
/// PDF and inspector toggles keep to the window's edge. Short of room, zoom overflows
/// first (with Share at the same priority, AppKit would hide both where Share still
/// fits), Compile and the toggles last (HIG, Toolbars).
///
/// Each action is its own item, so the system puts neighbours on one capsule; only zoom
/// and Math, whose middle or end segment opens a menu, are segmented controls.
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation, NSMenuItemValidation {
    let toolbar = NSToolbar(identifier: "Workspace")
    private let app: AppModel
    private let project: ProjectModel
    private let pdf: PDFController
    private weak var workspace: WorkspaceController?
    private var watch: Task<Void, Never>?

    init(app: AppModel, project: ProjectModel, pdf: PDFController, workspace: WorkspaceController) {
        self.app = app
        self.project = project
        self.pdf = pdf
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

    /// Leave room for the native title and Insert menu in a narrow source pane.
    /// AppKit only attempts to align tracking separators; it otherwise lets the
    /// formatting capsule push the line past the content divider. The same
    /// commands remain in Format and keep their keyboard shortcuts.
    func updateLayout() {
        guard let workspace else { return }
        let compact = workspace.sourceItem.viewController.view.bounds.width < 400
        for item in toolbar.items where [.bold, .italic].contains(item.itemIdentifier) {
            if item.isHidden != compact { item.isHidden = compact }
        }
    }

    func close() {
        watch?.cancel()
    }

    // ---------- items ----------

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .bold, .italic, .insert,
         .pdfSeparator, .zoom, .share, .flexibleSpace, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .togglePDF, .toggleInspector]
    }

    /// Customize Toolbar's items, by task; the window's own aren't offered.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undo, .redo, .sectionLevel, .bold, .italic, .math, .insert]
            + Self.buttonTemplates.map(NSToolbarItem.Identifier.template)
            + [.zoom, .share, .space, .flexibleSpace]
            + toolbarImmovableItemIdentifiers(toolbar)
    }

    /// The templates with a symbol, each a button; all are in the Insert menu.
    private static let buttonTemplates = (referenceTemplates + insertTemplates + listTemplates).filter { $0.symbol != nil }

    /// The window's own: the way back, the build and the columns.
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile, .togglePDF,
         .inspectorTrackingSeparator, .toggleInspector]
    }

    /// The system's sidebar and inspector toggles send `toggleSidebar:` and
    /// `toggleInspector:` down the responder chain, where the columns' own split view
    /// controllers, which have neither, would answer first: they go to the window's split.
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
            // Before the title (HIG, Toolbars: back leads). One level, no history to go forward.
            item.isNavigational = true
        case .undo:
            item = button(id, MenuCommand.editUndo.title, "arrow.uturn.backward", Selector(("undo:")))
            // Whatever has the keyboard, as the menu's Undo: it validates them too.
            item.target = nil
            item.visibilityPriority = .low
        case .redo:
            item = button(id, MenuCommand.editRedo.title, "arrow.uturn.forward", Selector(("redo:")))
            item.target = nil
            item.visibilityPriority = .low
        case .sectionLevel:
            item = sectionLevelItem()
        case .bold:
            item = button(id, MenuCommand.editBold.title, "bold", #selector(bold))
        case .italic:
            item = button(id, MenuCommand.editItalic.title, "italic", #selector(italic))
        case .math:
            item = mathItem()
            item.visibilityPriority = .low
        case .insert:
            let menu = NSMenuToolbarItem(itemIdentifier: id)
            menu.image = symbol("plus", "Insert")
            menu.label = "Insert"
            menu.toolTip = "Insert"
            menu.menu = NSHostingMenu(rootView: InsertMenuItems(project: project, inlineMath: inlineMath))
            item = menu
        case .pdfSeparator:
            guard let split = workspace?.columns.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case .zoom:
            item = zoomItem()
            item.visibilityPriority = .low
            // Customize Toolbar's default set squeezed its copy until the scale read
            // "…". The toolbar's own stays compressible: held at its width, it kept
            // the window 50 pt wider even in the overflow menu.
            if !flag { item.view?.setContentCompressionResistancePriority(.required, for: .horizontal) }
        case .share:
            let share = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            share.delegate = self
            share.label = "Share"
            share.toolTip = "Share PDF"
            item = share
        case .compile:
            // Its word, not a lone play symbol, which reads as media; the one
            // prominent control, on glass of its own. In the toolbar its own view,
            // for Stop's spinner (an item's image can't animate); Customize
            // Toolbar draws a view without the item's style, so it gets the title.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            item.possibleLabels = [MenuCommand.compileRun.title, MenuCommand.compileStop.title]
            if flag {
                item.view = NSHostingView(rootView: compileButton(state))
            } else {
                item.title = MenuCommand.compileRun.title
            }
            item.style = .prominent
            let form = NSMenuItem(title: MenuCommand.compileRun.title, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
            item.visibilityPriority = .high
        case .togglePDF:
            // A document's symbol: the PDF is the source's peer, not a sidebar or an inspector.
            item = button(id, "PDF", "richtext.page", #selector(togglePDF))
            item.possibleLabels = ["Show PDF", "Hide PDF"]
            item.visibilityPriority = .high
        default:
            guard let template = Self.buttonTemplates.first(where: { .template($0) == id }),
                  let symbolName = template.symbol else { return nil }
            item = button(id, template.title, symbolName, #selector(insertTemplate(_:)))
            item.visibilityPriority = .low
        }
        // Plain buttons are validated (`validateToolbarItem`, or for Undo and Redo the
        // responder that takes their action), and so are their copies in the overflow
        // menu; the rest take their state from the models (`apply`).
        if (item.target !== self && ![.undo, .redo].contains(id)) || item.view != nil {
            item.autovalidates = false
            (item as? NSToolbarItemGroup)?.subitems.forEach { $0.autovalidates = false }
        }
        if flag {
            configure(item, state)
            if [.bold, .italic].contains(id), let workspace {
                item.isHidden = workspace.sourceItem.viewController.view.bounds.width < 400
            }
        }
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

    /// Inline Math | Symbols: a segmented control whose second segment opens its menu.
    private func mathItem() -> NSToolbarItem {
        let control = NSSegmentedControl(images: [symbol("radicand.squareroot", MenuCommand.editMath.title),
                                                  symbol("sum", "Symbols")].compactMap(\.self),
                                         trackingMode: .momentary, target: self, action: #selector(math(_:)))
        control.setMenu(NSHostingMenu(rootView: SymbolItems(project: project)), forSegment: 1)
        control.setShowsMenuIndicator(true, forSegment: 1)
        let group = segmentGroup(.math, "Math", control, [MenuCommand.editMath.title, "Symbols"])
        let form = NSMenuItem(title: "Math", action: nil, keyEquivalent: "")
        form.submenu = NSHostingMenu(rootView: Group { [project, inlineMath] in
            inlineMath
            Section("Symbols") { SymbolItems(project: project) }
        })
        group.menuFormRepresentation = form
        return group
    }

    /// Zoom out | the scale | zoom in, one capsule; the scale opens a menu of fits and
    /// presets.
    private func zoomItem() -> NSToolbarItem {
        let control = NSSegmentedControl(images: [symbol("minus.magnifyingglass", "Zoom Out"), NSImage(),
                                                  symbol("plus.magnifyingglass", "Zoom In")].compactMap(\.self),
                                         trackingMode: .momentary, target: self, action: #selector(zoom(_:)))
        control.setImage(nil, forSegment: 1)
        control.setLabel(pdf.zoomLabel, forSegment: 1)
        control.setMenu(NSHostingMenu(rootView: ScaleMenuItems(pdf: pdf)), forSegment: 1)
        control.setShowsMenuIndicator(true, forSegment: 1)
        control.setAccessibilityLabel("Zoom")
        let group = segmentGroup(.zoom, "Zoom", control, ["Zoom Out", "Scale", "Zoom In"])
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        form.image = symbol("plus.magnifyingglass", "Zoom")
        form.submenu = NSHostingMenu(rootView: Group { [app, project, pdf] in
            // The menu bar's items carry the shortcuts.
            ForEach([MenuCommand.viewZoomIn, .viewZoomOut], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
                    .disabled(!app.isEnabled(command, on: project))
            }
            Divider()
            ScaleMenuItems(pdf: pdf)
        })
        group.menuFormRepresentation = form
        return group
    }

    /// A segmented control as a group: each segment a labelled subitem, with its tooltip.
    private func segmentGroup(_ id: NSToolbarItem.Identifier, _ label: String, _ control: NSSegmentedControl,
                              _ segments: [String]) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = label
        group.subitems = segments.enumerated().map { index, title in
            control.setToolTip(title, forSegment: index)
            let subitem = NSToolbarItem(itemIdentifier: .init(title))
            subitem.label = title
            return subitem
        }
        group.view = control
        return group
    }

    /// The caret line's section level; choosing one makes the line that heading.
    private func sectionLevelItem() -> NSToolbarItem {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for (index, level) in HeadingLevel.all.enumerated() {
            popUp.addItem(withTitle: level.title)
            popUp.lastItem?.tag = index
            if level == .normalText { popUp.menu?.addItem(.separator()) }
        }
        popUp.target = self
        popUp.action = #selector(sectionLevel(_:))
        popUp.toolTip = "Section Level"
        popUp.setAccessibilityLabel("Section Level")
        let item = NSToolbarItem(itemIdentifier: .sectionLevel)
        item.label = "Section Level"
        item.view = popUp
        let form = NSMenuItem(title: "Section Level", action: nil, keyEquivalent: "")
        form.submenu = NSHostingMenu(rootView: SectionLevelItems(project: project))
        item.menuFormRepresentation = form
        return item
    }

    /// Inline Math for the toolbar's menus; the menu bar's carries the shortcut.
    private var inlineMath: some View {
        Button(MenuCommand.editMath.title) { [app, project] in app.perform(.editMath, on: project) }
    }

    // ---------- state ----------

    /// What the items show, read from the models; a change redraws them.
    private nonisolated struct State: Equatable {
        var isLaTeX = false
        var sectionLevel = 0
        var hasPDF = false
        var showsPDF = true
        var zoomLabel = ""
        var canZoomIn = false
        var canZoomOut = false
        var compiling = false
        var canCompile = false
        var pdfTitle = ""
    }

    private var state: State {
        var state = State()
        state.isLaTeX = project.isLaTeX
        state.sectionLevel = HeadingLevel.all.firstIndex(of: project.headingLevel) ?? 0
        state.hasPDF = project.hasPDF
        state.showsPDF = project.showPDF
        state.zoomLabel = pdf.zoomLabel
        state.canZoomIn = pdf.canZoomIn
        state.canZoomOut = pdf.canZoomOut
        state.compiling = project.compiling
        state.canCompile = canCompile
        state.pdfTitle = app.title(.viewTogglePdf, on: project)
        return state
    }

    private func apply(_ state: State) {
        for item in toolbar.items { configure(item, state) }
    }

    private func configure(_ item: NSToolbarItem, _ state: State) {
        switch item.itemIdentifier {
        case .insert:
            item.isEnabled = state.isLaTeX
        case .math:
            item.isEnabled = state.isLaTeX
            (item as? NSToolbarItemGroup)?.subitems.forEach { $0.isEnabled = state.isLaTeX }
            (item.view as? NSSegmentedControl)?.isEnabled = state.isLaTeX
        case .sectionLevel:
            let popUp = item.view as? NSPopUpButton
            popUp?.isEnabled = state.isLaTeX
            popUp?.selectItem(withTag: state.sectionLevel)
            item.isEnabled = state.isLaTeX
        case .zoom:
            let control = item.view as? NSSegmentedControl
            // Tabular digits, so Share doesn't move as the scale changes. The toolbar
            // resets the control's font, so it's set with each label.
            if let font = control?.font { control?.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) }
            control?.setLabel(state.zoomLabel, forSegment: 1)
            control?.setEnabled(state.hasPDF && state.canZoomOut, forSegment: 0)
            control?.setEnabled(state.hasPDF, forSegment: 1)
            control?.setEnabled(state.hasPDF && state.canZoomIn, forSegment: 2)
            item.isEnabled = state.hasPDF
            // Only for the pages on screen.
            item.isHidden = !state.showsPDF
        case .share:
            item.isEnabled = state.hasPDF
        case .compile:
            // Stop in its place while a build runs, on clear glass: still prominent,
            // whose glass stays its own, where a plain item's joins its neighbours'.
            let title = state.compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title
            item.label = title
            item.toolTip = title
            item.menuFormRepresentation?.title = title
            item.backgroundTintColor = state.compiling ? .clear : nil
            item.isEnabled = state.canCompile
            (item.view as? NSHostingView<CompileButton>)?.rootView = compileButton(state)
        case .togglePDF:
            item.label = state.pdfTitle
            item.toolTip = state.pdfTitle
        case .pdfSeparator:
            guard let separator = item as? NSTrackingSeparatorToolbarItem, let workspace else { return }
            // A collapsed PDF's divider lies past the inspector partition, making
            // AppKit join the source's scroll edge to the whole toolbar. Track
            // that native partition instead, without rewriting the saved items.
            let split = state.showsPDF ? workspace.columns.splitView : workspace.splitView
            let divider = state.showsPDF ? 0 : workspace.splitViewItems.firstIndex(of: workspace.inspectorItem)! - 1
            guard separator.splitView !== split || separator.dividerIndex != divider else { return }
            // Index zero is valid in both splits while changing the tracked view.
            separator.dividerIndex = 0
            separator.splitView = split
            separator.dividerIndex = divider
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

    /// Compile, or Stop while a build runs.
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

    @objc private func math(_ control: NSSegmentedControl) {
        if control.selectedSegment == 0 { perform(.editMath) } else { openMenu(of: control) }
    }

    @objc private func zoom(_ control: NSSegmentedControl) {
        switch control.selectedSegment {
        case 0: pdf.zoom(in: false)
        case 2: pdf.zoom(in: true)
        default: openMenu(of: control)
        }
    }

    /// A segment's menu. AppKit opens it on a click only in a control without an
    /// action, and on a press and hold in one with: these have their other
    /// segments' action, so a click opens it here, under the control where it was
    /// clicked.
    private func openMenu(of control: NSSegmentedControl) {
        guard let menu = control.menu(forSegment: control.selectedSegment) else { return }
        let x = if let event = NSApp.currentEvent, event.type == .leftMouseUp {
            control.convert(event.locationInWindow, from: nil).x
        } else {
            control.bounds.midX
        }
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: control.isFlipped ? control.bounds.maxY : 0), in: control)
    }

    @objc private func sectionLevel(_ popUp: NSPopUpButton) {
        project.format(.heading, HeadingLevel.all[popUp.selectedTag()].command)
    }

    @objc private func compile() {
        perform(project.compiling ? .compileStop : .compileRun)
    }

    private func compileButton(_ state: State) -> CompileButton {
        CompileButton(compiling: state.compiling, enabled: state.canCompile) { [weak self] in
            self?.compile()
        }
    }

    /// The overflow menu's Compile, which the item's own view doesn't enable.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(compile) else { return true }
        return canCompile
    }

    @objc private func togglePDF() { perform(.viewTogglePdf) }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        project.pdfVersion > 0 ? project.pdfURL.map { [$0] } ?? [] : []
    }
}

/// Compile, or Stop with a spinner while a build runs. Both lay out and one shows,
/// so the button keeps Compile's width. It fills the item's glass, which passes no
/// clicks on to an item's own view.
private struct CompileButton: View {
    let compiling: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(MenuCommand.compileRun.title)
                    .opacity(compiling ? 0 : 1)
                HStack(spacing: BarMetrics.spacing) {
                    // The button stays a button to VoiceOver; the status bar says Compiling.
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(MenuCommand.compileStop.title)
                }
                .opacity(compiling ? 1 : 0)
            }
            // A toolbar item's glass, measured on macOS 27: 36 pt high, its title the
            // system font, 12 pt from the ends.
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
    }
}
