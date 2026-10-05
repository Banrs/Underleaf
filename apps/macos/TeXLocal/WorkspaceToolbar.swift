import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let undo = Self("undo")
    static let redo = Self("redo")
    static let format = Self("sectionLevel")
    static let bold = Self("bold")
    static let italic = Self("italic")
    static let underline = Self("underline")
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
/// Related tools share a capsule (HIG, Toolbars): the editing tools are separate items that
/// AppKit joins side by side, as Xcode's and Notes'; the PDF and Inspector toggles stay apart.
/// The window's minimum fits every default item over its pane (`ColumnMetrics`). Should added
/// items crowd them, the least used in TeX editors leave first: Zoom, then the editing tools
/// (equal priorities leave from the right). Back, Compile and the toggles stay (HIG, Toolbars).
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation, NSMenuItemValidation {
    /// Renamed as the defaults change: a layout saved under "Workspace" has Share, and one
    /// under "Workspace 2" the toggles' former group, which would come back or go missing.
    let toolbar = NSToolbar(identifier: "Workspace 3")
    private let app: AppModel
    private let project: ProjectModel
    private var pdf: PDFController { project.pdf }
    private weak var workspace: WorkspaceController?
    /// Aa's.
    private(set) lazy var format = FormatPopover(app: app, project: project)
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
        format.popover.close()
    }

    // ---------- items ----------

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .format, .math, .insert,
         .pdfSeparator, .zoom, .flexibleSpace, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .togglePDF, .toggleInspector]
    }

    /// Share is here only: File › Share has it.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undo, .redo, .format, .bold, .italic, .underline, .math, .insert]
            + Self.buttonTemplates.map(NSToolbarItem.Identifier.template)
            + [.zoom, .share, .space, .flexibleSpace]
            + toolbarImmovableItemIdentifiers(toolbar)
    }

    private static let buttonTemplates = (referenceTemplates + insertTemplates + listTemplates).filter { $0.symbol != nil }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile,
         .inspectorTrackingSeparator, .toggleInspector]
    }

    /// The system's toggles go to the window's split, not the nested ones, which would answer first.
    /// They stay out of the overflow menu, as the leading and trailing edges' items do (HIG, Toolbars).
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              [.toggleSidebar, .toggleInspector].contains(item.itemIdentifier) else { return }
        item.target = workspace
        item.visibilityPriority = .high
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .back:
            item = button(id, "Projects", "chevron.backward", #selector(back), help: "Back to Projects")
            // Back leads the title; there is no forward history.
            item.isNavigational = true
            item.visibilityPriority = .high
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
        case .math:
            item = menuItem(id, "Math", "radicand.squareroot", MathMenuItems(project: project) { [app, project] in
                app.perform(.editMath, on: project)
            })
        case .insert:
            // Notes' ellipsis, which means More (HIG, Icons), with Insert as its name for
            // VoiceOver, Customize Toolbar and the overflow menu: what it holds is the menu bar's Insert.
            item = menuItem(id, "Insert", "ellipsis", InsertMenuItems(project: project))
        case .bold:
            item = button(id, MenuCommand.editBold.title, "bold", #selector(bold))
            item.visibilityPriority = .low
        case .italic:
            item = button(id, MenuCommand.editItalic.title, "italic", #selector(italic))
            item.visibilityPriority = .low
        case .underline:
            item = button(id, MenuCommand.editUnderline.title, "underline", #selector(underline))
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
            // The window's one prominent action (HIG Toolbars), as a word: a play symbol reads as
            // media. Customize Toolbar gets a title, as it draws custom views without their style.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            if flag {
                item.view = NSHostingView(rootView: compileButton(compiling: project.compiling, enabled: canCompile))
            } else {
                item.title = MenuCommand.compileRun.title
            }
            // The labelled form too: sized for the longer of its two labels.
            item.possibleLabels = [MenuCommand.compileRun.title, MenuCommand.compileStop.title]
            let form = NSMenuItem(title: MenuCommand.compileRun.title, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
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
        // Other controls take their state from the models (`configure`).
        if (item.target !== self && ![.undo, .redo].contains(item.itemIdentifier)) || item.view != nil {
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
        // Three segments whatever the symbols: `zoom` reads them by index.
        let control = ZoomControl()
        control.segmentCount = 3
        control.trackingMode = .momentary
        control.addTarget(self, action: #selector(zoom(_:)), for: .primaryActionTriggered)
        control.setImage(symbol("minus.magnifyingglass", "Zoom Out"), forSegment: 0)
        control.setImage(symbol("plus.magnifyingglass", "Zoom In"), forSegment: 2)
        control.setLabel(pdf.zoomLabel, forSegment: 1)
        control.widestLabel = pdf.widestZoomLabel
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
        item.visibilityPriority = .low
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
        // No chevrons, as Notes' tools: with them, each menu draws its own capsule (27.2).
        item.showsIndicator = false
        item.visibilityPriority = .low
        return item
    }

    /// Aa opens its popover (`FormatPopover`); the overflow menu has the same as a menu.
    private func formatItem() -> NSToolbarItem {
        let item = button(.format, "Format", "textformat", #selector(showFormat(_:)))
        let form = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        form.image = item.image
        form.submenu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.isLaTeX }) { [app, project] in
            ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
            }
            Divider()
            SectionLevelItems(project: project)
        })
        item.menuFormRepresentation = form
        // Off outside LaTeX, as Math and Insert (`configure`).
        item.autovalidates = false
        item.visibilityPriority = .low
        return item
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
    }

    private var state: State {
        State(isLaTeX: project.isLaTeX,
              hasPDF: project.hasPDF, showsPDF: app.showPDF,
              zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
              compiling: project.compiling, canCompile: canCompile,
              pdfTitle: app.title(.viewTogglePdf, on: project))
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
        for item in toolbar.items { configure(item, state, from: applied) }
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
            if changed(\.zoomLabel) { control?.setLabel(state.zoomLabel, forSegment: 1) }
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
                // Stop on clear glass: still prominent, whose glass stays its own, where a plain
                // item's joins its neighbours'.
                item.backgroundTintColor = state.compiling ? .clear : nil
            }
            if changed(\.canCompile) { item.isEnabled = state.canCompile }
            if changed(\.compiling) || changed(\.canCompile) {
                (item.view as? NSHostingView<CompileButton>)?.rootView = compileButton(compiling: state.compiling,
                                                                                      enabled: state.canCompile)
            }
        case .togglePDF:
            if changed(\.pdfTitle) { item.toolTip = state.pdfTitle }
        default:
            break
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .bold, .italic, .underline: project.isLaTeX
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

    @objc private func showFormat(_ sender: Any?) {
        guard let item = sender as? NSToolbarItem ?? toolbar.items.first(where: { $0.itemIdentifier == .format }) else { return }
        format.toggle(relativeTo: item)
    }

    @objc private func bold() { perform(.editBold) }

    @objc private func italic() { perform(.editItalic) }

    @objc private func underline() { perform(.editUnderline) }

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

    private func compileButton(compiling: Bool, enabled: Bool) -> CompileButton {
        CompileButton(compiling: compiling, enabled: enabled) { [weak self] in self?.compile() }
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

/// Zoom's segments, which keep one width as the scale changes, as a pop-up keeps its widest
/// item's: otherwise the capsule, and the items after it, move. The percentage keeps tabular
/// digits in whatever font the toolbar gives the control, in the widest label's width.
private final class ZoomControl: NSSegmentedControl {
    var widestLabel = "" { didSet { reserveWidth() } }

    override var font: NSFont? {
        get { super.font }
        set {
            super.font = newValue.map { .monospacedDigitSystemFont(ofSize: $0.pointSize, weight: .regular) }
            reserveWidth()
        }
    }

    /// AppKit gives the control the size's own font.
    override var controlSize: NSControl.ControlSize {
        didSet { font = font }
    }

    private var reserving = false

    /// After the change that asks for it: inside the toolbar's own update, as it sets the font
    /// on showing a hidden item, the control's size lags each change by one, and the round trip
    /// below widened the scale each time the PDF came back (27.2).
    private func reserveWidth() {
        guard !reserving else { return }
        reserving = true
        DispatchQueue.main.async { [weak self] in
            self?.reserving = false
            self?.measure()
        }
    }

    /// A set width gets the same margins as a label's own: the widest label's width, less them.
    private func measure() {
        guard !widestLabel.isEmpty, segmentCount == 3 else { return }
        let label = label(forSegment: 1) ?? ""
        setLabel(widestLabel, forSegment: 1)
        setWidth(0, forSegment: 1)
        let widest = intrinsicContentSize.width
        setWidth(widest, forSegment: 1)
        let margins = intrinsicContentSize.width - widest
        setWidth(widest - margins, forSegment: 1)
        setLabel(label, forSegment: 1)
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

/// Compile as its word, and Stop with a spinner in Compile's width. It fills the item's glass,
/// which doesn't pass clicks on to an undersized custom view.
private struct CompileButton: View {
    let compiling: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(MenuCommand.compileRun.title)
                    .opacity(compiling ? 0 : 1)
                HStack(spacing: 4) {
                    // The button stays a button to VoiceOver; the status bar says Compiling.
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(MenuCommand.compileStop.title)
                }
                .opacity(compiling ? 1 : 0)
            }
            // The item's glass as AppKit draws a titled item's: 36 points high (the UI kit's
            // toolbar controls), the title 12 points in from each end, 74 points for Compile (27.2).
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
    }
}
