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
/// What a narrow window has no room for goes to the system's overflow menu, each tool with a
/// menu form. The least used in TeX editors leave first: Zoom, then the editing tools (equal
/// priorities leave from the right). Back, Compile and the toggles go last (HIG, Toolbars).
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation, NSMenuItemValidation {
    /// Renamed as the defaults change: a layout saved under an earlier name has Share, the
    /// toggles' former group or no PDF toggle, which would come back or stay missing.
    let toolbar = NSToolbar(identifier: "Workspace 4")
    /// Compile as its symbol, which the workspace sets where its word would be the first tool
    /// without room.
    var compactCompile: Bool {
        get { fit.compact }
        set { if fit.compact != newValue { fit.compact = newValue } }
    }
    private let fit = Fit()
    @Observable final class Fit { var compact = false }
    private let app: AppModel
    private let project: ProjectModel
    private var pdf: PDFController { project.pdf }
    private weak var workspace: WorkspaceController?
    /// Aa's.
    private lazy var format = FormatPopover(app: app, project: project)
    /// What the items show; `watch` sets only what differs from it.
    private var applied: State?
    private var customized: NSKeyValueObservation?
    private var closed = false

    init(app: AppModel, project: ProjectModel, workspace: WorkspaceController) {
        self.app = app
        self.project = project
        self.workspace = workspace
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Compile's word is the one label, and the workspace knows its width (`ColumnMetrics`).
        toolbar.allowsDisplayModeCustomization = false
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        // Customize Toolbar's changes, for Compile's form (`holdsDefaultItems`): a turn later,
        // once AppKit has done with its items.
        customized = toolbar.observe(\.itemIdentifiers) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.workspace?.toolbarItemsChanged() }
        }
        watch()
    }

    func close() {
        closed = true
        customized = nil
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
         .inspectorTrackingSeparator, .togglePDF, .toggleInspector]
    }

    /// Whether the toolbar holds its default tools, spaces aside: the ones whose widths the
    /// workspace reckons Compile's room from (`fitToolbar`).
    var holdsDefaultItems: Bool {
        func tools(_ ids: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
            ids.filter { $0 != .space && $0 != .flexibleSpace }
        }
        return tools(toolbar.itemIdentifiers) == tools(toolbarDefaultItemIdentifiers(toolbar))
    }

    /// The system's toggles go to the window's split, not the nested ones, which would answer first.
    /// They stay out of the overflow menu, as the leading and trailing edges' items do (HIG, Toolbars).
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem,
              [.toggleSidebar, .toggleInspector].contains(item.itemIdentifier) else { return }
        item.target = workspace
        item.visibilityPriority = .high
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .back:
            // Back by name, for VoiceOver and the overflow menu: where to is its help tag's to say.
            item = button(id, "Back", "chevron.backward", #selector(back), help: "Return to Projects")
            // Back leads the title; there is no forward history.
            item.isNavigational = true
        case .undo:
            item = button(id, "Undo", "arrow.uturn.backward", Selector(("undo:")), help: "Undo the last change")
            // Whatever has the keyboard, as the menu's Undo: it validates them too.
            item.target = nil
        case .redo:
            item = button(id, "Redo", "arrow.uturn.forward", Selector(("redo:")), help: "Redo the last undone change")
            item.target = nil
        case .format:
            item = formatItem()
        case .math:
            item = menuItem(id, "Math", "radicand.squareroot",
                            MathMenuItems(project: project) { [app, project] in app.perform(.editMath, on: project) },
                            help: "Insert math or a symbol")
        case .insert:
            // Notes' ellipsis, which means More (HIG, Icons), with Insert as its name for
            // VoiceOver, Customize Toolbar and the overflow menu: what it holds is the menu bar's Insert.
            item = menuItem(id, "Insert", "ellipsis", InsertMenuItems(project: project),
                            help: "Insert a figure, table, list or reference")
        case .bold:
            item = button(id, MenuCommand.editBold.title, "bold", #selector(bold), help: "Make text bold")
        case .italic:
            item = button(id, MenuCommand.editItalic.title, "italic", #selector(italic), help: "Make text italic")
        case .underline:
            item = button(id, MenuCommand.editUnderline.title, "underline", #selector(underline), help: "Underline text")
        case .pdfSeparator:
            guard let split = workspace?.columns.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case .zoom:
            item = zoomItem()
        case .share:
            let share = ShareItem(itemIdentifier: id)
            share.delegate = self
            share.toolTip = "Share the PDF"
            item = share
        case .compile:
            // The window's one prominent action (HIG Toolbars), as a word: a play symbol reads as
            // media. It stands for the word only where the word doesn't fit (`CompileButton`).
            // Customize Toolbar gets a title, as it draws custom views without their style.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            if flag {
                item.view = NSHostingView(rootView: compileButton(state))
            } else {
                item.title = MenuCommand.compileRun.title
            }
            // Enabled by `validateMenuItem`, as the button by the models (`configure`).
            let form = NSMenuItem(title: MenuCommand.compileRun.title, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
            item.style = .prominent
        case .togglePDF:
            // A document's symbol: the PDF is the source's peer, not a sidebar or an inspector.
            // In the toolbar its help tag says which it will do, as the menu's title (`configure`).
            item = button(id, "PDF", "richtext.page", #selector(togglePDF), help: "Show or hide the PDF")
        default:
            guard let template = Self.buttonTemplates.first(where: { .template($0) == id }),
                  let symbolName = template.symbol else { return nil }
            // The templates with symbols are named by common nouns: Figure, Bulleted List, Link.
            item = button(id, template.title, symbolName, #selector(insertTemplate(_:)),
                          help: "Insert \(template.title.lowercased())")
        }
        // Plain buttons and their overflow copies validate through their targets.
        // Other controls take their state from the models (`configure`).
        if (item.target !== self && ![.undo, .redo].contains(item.itemIdentifier)) || item.view != nil {
            item.autovalidates = false
        }
        // Back, Compile and the PDF's toggle are the last to leave for the overflow menu, with the
        // system's toggles (`toolbarWillAddItem`); the rest are the first.
        item.visibilityPriority = [.back, .compile, .togglePDF].contains(id) ? .high : .low
        if flag { configure(item, state) }
        return item
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    /// A symbol's button. Its label is its name, for VoiceOver, Customize Toolbar and the overflow
    /// menu; its help tag says what it does (HIG, Offering help: not the name again).
    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbolName: String, _ action: Selector,
                        help: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = help
        item.image = symbol(symbolName, label)
        item.target = self
        item.action = action
        return item
    }

    /// Zoom out | scale menu | zoom in, one native capsule. Its menu form is a title alone, as
    /// Format's, Compile's and the forms AppKit makes for the plain items beside them.
    private func zoomItem() -> NSToolbarItem {
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
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
        for (index, help) in ["Zoom out of the PDF", "Choose a zoom level", "Zoom in on the PDF"].enumerated() {
            control.setToolTip(help, forSegment: index)
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
                          _ items: some View, help: String) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = title
        item.toolTip = help
        item.image = symbol(image, title)
        item.menu = menu(items)
        // No chevrons, as Notes' tools: with them, each menu draws its own capsule (27.2).
        item.showsIndicator = false
        return item
    }

    private func menu(_ items: some View) -> NSMenu {
        NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.isLaTeX }) { items })
    }

    /// Aa opens its popover (`FormatPopover`); the overflow menu has the same as a menu.
    private func formatItem() -> NSToolbarItem {
        // Notes' words, from its strings (27.2).
        let item = button(.format, "Format", "textformat", #selector(showFormat(_:)), help: "Choose a style to apply to text")
        let form = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        form.submenu = menu(Group { [app, project] in
            ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
            }
            Divider()
            SectionLevelItems(project: project)
        })
        item.menuFormRepresentation = form
        // Off outside LaTeX, as Math and Insert (`configure`).
        item.autovalidates = false
        return item
    }

    // ---------- state ----------

    private nonisolated struct State: Equatable {
        let isLaTeX: Bool
        let hasPDF: Bool
        let canShare: Bool
        let showsPDF: Bool
        let zoomLabel: String
        let canZoomIn: Bool
        let canZoomOut: Bool
        let compiling: Bool
        let canCompile: Bool
        let compactCompile: Bool
    }

    private var state: State {
        State(isLaTeX: project.isLaTeX,
              hasPDF: project.hasPDF, canShare: project.buildPDF != nil, showsPDF: app.showPDF,
              zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
              compiling: project.compiling, canCompile: canCompile, compactCompile: fit.compact)
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
            if changed(\.canShare) { item.isEnabled = state.canShare }
        case .compile:
            let command = state.compiling ? MenuCommand.compileStop : .compileRun
            if changed(\.compiling) {
                item.label = command.title
                item.menuFormRepresentation?.title = command.title
                // Stop on clear glass: still prominent, whose glass stays its own, where a plain
                // item's joins its neighbours'.
                item.backgroundTintColor = state.compiling ? .clear : nil
            }
            if changed(\.canCompile) { item.isEnabled = state.canCompile }
            // A help tag for the symbol alone: the word says as much itself (HIG, Buttons).
            if changed(\.compiling) || changed(\.compactCompile) {
                item.toolTip = !state.compactCompile ? nil : state.compiling ? "Stop the build" : "Compile the project"
            }
            if changed(\.compiling) || changed(\.compactCompile) || changed(\.canCompile) {
                (item.view as? NSHostingView<CompileButton>)?.rootView = compileButton(state)
            }
        case .togglePDF:
            if changed(\.showsPDF) { item.toolTip = app.title(.viewTogglePdf, on: project) }
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

    private func compileButton(_ state: State) -> CompileButton {
        CompileButton(compiling: state.compiling, compact: state.compactCompile, enabled: state.canCompile) { [weak self] in
            self?.compile()
        }
    }

    @objc private func togglePDF() { perform(.viewTogglePdf) }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        project.buildPDF.map { [$0] } ?? []
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
        Task { [weak self] in
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

/// Compile as its word, or as its symbol where the word has no room, and Stop with the build's
/// spinner in the width Compile has there. It fills the item's glass, which doesn't pass clicks
/// on to an undersized custom view. It changes form as AppKit's search item goes to its button
/// and back (27.2, measured): the width in one step, the symbol fading in, or out over the word,
/// in a fifth of a second on Core Animation's default curve.
private struct CompileButton: View {
    let compiling: Bool
    let compact: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Button(action: action) {
            ZStack {
                idle.opacity(compiling ? 0 : 1)
                // The button stays a button to VoiceOver; the status bar says Compiling.
                busy.opacity(compiling ? 1 : 0)
                    .accessibilityHidden(true)
            }
            // Faint in a window that isn't the active one, as AppKit's own items, Stop as Compile.
            .foregroundStyle(appearsActive ? .primary : .tertiary)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2), value: compact)
            // The item's glass as AppKit draws a titled item's and a symbol's: 36 points high (the
            // UI kit's toolbar controls), a title 12 points in from each end, 74 points for
            // Compile, and a circle for a symbol (27.2).
            .padding(.horizontal, compact ? 0 : 12)
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
    }

    @ViewBuilder private var idle: some View {
        if compact {
            // At the size AppKit draws an item's symbol (27.2), measured.
            Image(systemName: "play.fill").font(.system(size: 17))
        } else {
            Text(MenuCommand.compileRun.title).transition(.identity)
        }
    }

    /// The spinner beside Stop's word, or round its symbol: the regular spinner, 32 points, would
    /// touch the circle's edge, and the small one has no room inside it.
    @ViewBuilder private var busy: some View {
        if compact {
            ZStack {
                ProgressView().controlSize(.regular).scaleEffect(0.8)
                Image(systemName: "stop.fill").font(.system(size: 7))
            }
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(MenuCommand.compileStop.title)
            }
            .transition(.identity)
        }
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
