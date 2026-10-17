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
    static let pdfSeparator = Self("pdfSeparator")
    static let zoom = Self("zoom")
    static let share = Self("share")
    static let compile = Self("compile")
    static let togglePDF = Self("togglePDF")

    static func template(_ template: Template) -> Self { Self("template." + template.title) }
}

/// What a narrow window has no room for goes to the system's overflow menu: Zoom leaves first, then the editing tools,
/// then Back, Compile and the toggles (HIG, Toolbars).
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation, NSMenuItemValidation {
    /// Renamed as the defaults change: a layout saved under an earlier name would bring back or lack items.
    let toolbar = NSToolbar(identifier: "Workspace 5")
    private let app: AppModel
    private let project: ProjectModel
    private var pdf: PDFController { project.pdf }
    /// Set by the workspace that owns the toolbar, as it has finished initialising.
    weak var workspace: WorkspaceController?
    private lazy var format = FormatPopover(app: app, project: project)
    private var applied: State?
    private var closed = false
    private var resized: NotificationCenter.ObservationToken?

    init(app: AppModel, project: ProjectModel) {
        self.app = app
        self.project = project
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Compile is its word already: with labels it would say it twice.
        toolbar.allowsDisplayModeCustomization = false
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = app.savesLayout
        watch()
    }

    func close() {
        closed = true
        format.popover.close()
    }

    // MARK: - Items

    /// Each pane's tools at its trailing end, as each column's in Mail and the tools after the title in the UI kit's
    /// toolbar: Zoom beside Compile, the window's one prominent action, on the trailing side (HIG, Toolbars).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .format, .math, .insert,
         .pdfSeparator, .flexibleSpace, .zoom, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .togglePDF, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undo, .redo, .format, .bold, .italic, .underline, .math, .insert]
            + Self.buttonTemplates.map(NSToolbarItem.Identifier.template)
            + [.zoom, .share, .space, .flexibleSpace]
            + toolbarImmovableItemIdentifiers(toolbar)
    }

    private static let buttonTemplates: [Template] = {
        let templates = Menus.shared.templates
        return (templates.references + templates.insert + templates.list).filter { $0.symbol != nil }
    }()

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile,
         .inspectorTrackingSeparator, .togglePDF, .toggleInspector]
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
            item = button(id, "Back", "chevron.backward", #selector(back), help: "Return to Projects")
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
            item = menuItem(id, "Insert", "ellipsis", InsertMenuItems(project: project),
                            help: "Insert a figure, table, list or reference")
        case .bold, .italic, .underline:
            let (command, help) = Self.styles[id]!
            item = button(id, command.title, command.symbol!, #selector(style(_:)), help: help)
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
            // The window's one prominent action (HIG, Toolbars), as a word: a play symbol reads as media. It stands for
            // the word only where the word doesn't fit (`CompileButton`). Customize Toolbar gets a title, as it draws
            // custom views without their style.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            if flag {
                let view = CompileHost(rootView: compileButton(state))
                view.sizingOptions = [.minSize, .maxSize]
                item.view = view
                // A wider section may have room for the word again.
                if let split = workspace?.columns.splitView {
                    resized = NotificationCenter.default.addObserver(of: split, for: .didResizeSubviews) { _ in
                        view.offerWord()
                    }
                }
            } else {
                item.title = MenuCommand.compileRun.title
            }
            item.style = .prominent
            // Enabled by `validateMenuItem`, as the button by the models (`configure`).
            let form = NSMenuItem(title: MenuCommand.compileRun.title, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
        case .togglePDF:
            item = button(id, "PDF", "richtext.page", #selector(togglePDF), help: "Show or hide the PDF")
        default:
            guard let template = Self.buttonTemplates.first(where: { .template($0) == id }),
                  let symbolName = template.symbol else { return nil }
            item = button(id, template.title, symbolName, #selector(insertTemplate(_:)),
                          help: "Insert \(template.title.lowercased())")
        }
        // Plain buttons and their overflow copies validate through their targets; other controls take their state from the models (`configure`).
        if (item.target !== self && ![.undo, .redo].contains(item.itemIdentifier)) || item.view != nil {
            item.autovalidates = false
        }
        item.visibilityPriority = [.back, .compile, .togglePDF].contains(id) ? .high : .low
        if flag { configure(item, state) }
        return item
    }

    private static let styles: [NSToolbarItem.Identifier: (MenuCommand, help: String)] = [
        .bold: (.editBold, "Make text bold"), .italic: (.editItalic, "Make text italic"), .underline: (.editUnderline, "Underline text"),
    ]

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    /// Its help tag says what it does (HIG, Offering help: not the name again).
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

    private func zoomItem() -> NSToolbarItem {
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let menu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.hasPDF }) { [app, project, pdf] in
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

    // MARK: - State

    /// Off, all of it, while a project opened over this one loads (`MainWindowController.showProject`).
    private nonisolated struct State: Equatable {
        let isLaTeX, hasPDF, canShare, showsPDF: Bool
        let zoomLabel: String
        let canZoomIn, canZoomOut, compiling, canCompile: Bool
    }

    private var state: State {
        let open = !project.closed
        return State(isLaTeX: open && project.isLaTeX, hasPDF: open && project.hasPDF, canShare: open && project.buildPDF != nil,
                     showsPDF: app.showPDF, zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
                     compiling: project.compiling, canCompile: canCompile)
    }

    /// A column resizing refits the PDF during layout, and an async `track` would set the new scale a pass later:
    /// the toolbar would draw each frame of a sidebar's animation twice.
    private func watch() {
        guard !closed else { return }
        apply(withObservationTracking(options: .didSet) { state } onChange: { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        })
    }

    private func apply(_ state: State) {
        guard !closed, state != applied else { return }
        for item in toolbar.items { configure(item, state) }
        applied = state
    }

    private func configure(_ item: NSToolbarItem, _ state: State) {
        switch item.itemIdentifier {
        case .format, .math, .insert:
            item.isEnabled = state.isLaTeX
        case .zoom:
            guard let control = item.view as? NSSegmentedControl else { return }
            // Set as it changes: a segment's label, set unchanged, still lays the toolbar out again, as each frame of a
            // pane's animation refits the PDF.
            if control.label(forSegment: 1) != state.zoomLabel { control.setLabel(state.zoomLabel, forSegment: 1) }
            control.setEnabled(state.hasPDF && state.canZoomOut, forSegment: 0)
            control.setEnabled(state.hasPDF, forSegment: 1)
            control.setEnabled(state.hasPDF && state.canZoomIn, forSegment: 2)
            item.isEnabled = state.hasPDF
            if item.isHidden == state.showsPDF { item.isHidden = !state.showsPDF }
        case .share:
            item.isEnabled = state.canShare
        case .compile:
            let command = state.compiling ? MenuCommand.compileStop : .compileRun
            if item.label != command.title {
                item.label = command.title
                item.menuFormRepresentation?.title = command.title
                // Stop on clear glass: a prominent item's glass stays its own, where a plain item's joins its neighbours'.
                item.backgroundTintColor = state.compiling ? .clear : nil
            }
            item.isEnabled = state.canCompile
            if let view = item.view as? CompileHost {
                view.rootView = compileButton(state, compact: view.rootView.compact)
            }
        case .togglePDF:
            item.toolTip = app.title(.viewTogglePDF, on: project)
        default:
            break
        }
    }

    /// The buttons, and their copies in the overflow menu, which AppKit validates through their target.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        allows(item.action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        allows(menuItem.action)
    }

    private func allows(_ action: Selector?) -> Bool {
        guard !project.closed else { return false }
        switch action {
        case #selector(style(_:)), #selector(insertTemplate(_:)): return project.isLaTeX
        // The overflow menu's Compile, which the item's own view doesn't enable.
        case #selector(compile): return canCompile
        default: return true
        }
    }

    private var canCompile: Bool {
        !project.closed && (project.compiling || app.isEnabled(.compileRun, on: project))
    }

    // MARK: - Actions

    @objc private func back() { app.perform(.projectClose, on: project) }

    /// A toolbar button's action comes from its item, as `insertTemplate`'s does (27.2).
    @objc private func showFormat(_ item: NSToolbarItem) {
        format.toggle(relativeTo: item)
    }

    @objc private func style(_ item: NSToolbarItem) {
        if let (command, _) = Self.styles[item.itemIdentifier] { app.perform(command, on: project) }
    }

    @objc private func insertTemplate(_ item: NSToolbarItem) {
        guard let template = Self.buttonTemplates.first(where: { .template($0) == item.itemIdentifier }) else { return }
        project.insert(template)
    }

    @objc private func zoom(_ control: NSSegmentedControl) {
        guard control.selectedSegment == 0 || control.selectedSegment == 2 else { return }
        pdf.zoom(in: control.selectedSegment == 2)
    }

    @objc private func compile() {
        app.perform(project.compiling ? .compileStop : .compileRun, on: project)
    }

    private func compileButton(_ state: State, compact: Bool = false) -> CompileButton {
        CompileButton(compiling: state.compiling, compact: compact, enabled: state.canCompile) { [weak self] in
            self?.compile()
        }
    }

    @objc private func togglePDF() { app.perform(.viewTogglePDF, on: project) }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        project.buildPDF.map { [$0] } ?? []
    }
}

/// The menu asks the item, and AppKit's answer for it ignores `isEnabled` (27.2).
private final class ShareItem: NSSharingServicePickerToolbarItem {
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled && super.validateMenuItem(menuItem)
    }
}

/// The segments keep one width as the scale changes, and the percentage tabular digits: otherwise the capsule, and the items after it, move.
private final class ZoomControl: NSSegmentedControl {
    var widestLabel = ""
    private var measuredSize: CGFloat?

    override var font: NSFont? {
        get { super.font }
        set { super.font = newValue.map { .monospacedDigitSystemFont(ofSize: $0.pointSize, weight: .regular) } }
    }

    override var controlSize: NSControl.ControlSize {
        didSet { font = font }
    }

    /// Inside the toolbar's own update the control's size lags each font change by one (27.2).
    override func layout() {
        super.layout()
        guard let size = font?.pointSize, size != measuredSize else { return }
        measuredSize = size
        measure()
    }

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

/// Compile's view. The toolbar sizes a custom view anywhere between its least and greatest widths, which would leave the
/// symbol in a capsule as wide as the room: given less than the word, it takes the symbol's circle, and a wider section
/// offers the word again (`offerWord`), as AppKit's search item folds to its button.
private final class CompileHost: NSHostingView<CompileButton> {
    /// The word's width, Compile's or Stop's, whichever is wider: the item's own `fittingSize` is its least.
    private lazy var word = NSHostingView(rootView: CompileButton(compiling: false, compact: false, enabled: true) {})
        .intrinsicContentSize.width

    /// The toolbar places an item at its least width before its own (27.2), so the first width after it is placed is
    /// judged a turn later.
    private var placed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Into the toolbar, or back from its overflow menu: there may be room for the word.
        placed = false
        offerWord()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if placed {
            fold()
        } else {
            placed = true
            Task { [weak self] in self?.fold() }
        }
    }

    private func fold() {
        if !rootView.compact, frame.width < word - 0.5 { rootView.compact = true }
    }

    func offerWord() {
        if rootView.compact { rootView.compact = false }
    }
}

/// Compile as its word, or as its symbol where the toolbar has no room for the word, and Stop with the build's spinner in
/// the width Compile has there. It fills the item's glass, which doesn't pass clicks on to an undersized custom view.
private struct CompileButton: View {
    let compiling: Bool
    var compact: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Button(action: action) {
            ZStack {
                idle(compact).opacity(compiling ? 0 : 1)
                // The button stays a button to VoiceOver; the status bar says Compiling.
                busy(compact).opacity(compiling ? 1 : 0)
                    .accessibilityHidden(true)
            }
            // Faint in a window that isn't the active one, as AppKit's own items, Stop as Compile.
            .foregroundStyle(appearsActive ? .primary : .tertiary)
            // The item's glass as AppKit draws a titled item's and a symbol's: 36 points high (the UI kit's toolbar
            // controls), a title 12 points in from each end, and a circle for a symbol (27.2).
            .padding(.horizontal, compact ? 0 : 12)
            .frame(minWidth: 36, maxWidth: compact ? 36 : nil, minHeight: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
        // A help tag for the symbol alone: the word says as much itself (HIG, Buttons).
        .help(compact ? (compiling ? "Stop the build" : "Compile the project") : "")
    }

    @ViewBuilder private func idle(_ compact: Bool) -> some View {
        if compact {
            // At the size AppKit draws an item's symbol (27.2), measured.
            Image(systemName: "play.fill").font(.system(size: 17))
        } else {
            Text(MenuCommand.compileRun.title).lineLimit(1)
        }
    }

    /// The spinner beside Stop's word, or round its symbol: the regular spinner, 32 points, would touch the circle's
    /// edge, and the small one has no room inside it.
    @ViewBuilder private func busy(_ compact: Bool) -> some View {
        if compact {
            ZStack {
                ProgressView().controlSize(.regular).scaleEffect(0.8)
                Image(systemName: "stop.fill").font(.system(size: 7))
            }
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(MenuCommand.compileStop.title).lineLimit(1)
            }
        }
    }
}

/// The overflow menu still opens the menu, which stays available with its items dimmed (HIG, Menus).
private struct ToolbarMenuItems<Content: View>: View {
    let isEnabled: () -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().disabled(!isEnabled())
    }
}
