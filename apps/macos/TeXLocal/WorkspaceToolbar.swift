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

/// What a narrow window has no room for goes to the overflow menu, the editing tools and Zoom first (HIG, Toolbars).
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSToolbarItemValidation, NSMenuItemValidation {
    /// Renamed as the defaults change: a layout saved under an earlier name would bring back or lack items.
    let toolbar = NSToolbar(identifier: "Workspace 5")
    /// Compile as its symbol, where the workspace finds its word would be the first tool without room.
    var compactCompile = false { didSet { if compactCompile != oldValue { apply(state) } } }
    private let app: AppModel
    private let project: ProjectModel
    private var pdf: PDFController { project.pdf }
    weak var workspace: WorkspaceController?
    private lazy var format = FormatPopover(app: app, project: project)
    private var customized: NSKeyValueObservation?
    private var closed = false

    init(app: AppModel, project: ProjectModel) {
        self.app = app
        self.project = project
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Compile's word is the one label, and the workspace knows its width.
        toolbar.allowsDisplayModeCustomization = false
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = app.savesLayout
        // A turn later, once AppKit has done with its items.
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

    // MARK: - Items

    /// Each pane's tools at its trailing end, as Mail's columns', with Zoom beside Compile (HIG, Toolbars).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .format, .math, .insert,
         .pdfSeparator, .flexibleSpace, .zoom, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .togglePDF, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undo, .redo, .format, .bold, .italic, .underline, .math, .insert] + Self.buttonTemplates.map(NSToolbarItem.Identifier.template)
            + [.zoom, .share, .space, .flexibleSpace] + toolbarImmovableItemIdentifiers(toolbar)
    }

    private static let buttonTemplates: [Template] = {
        let templates = Menus.shared.templates
        return (templates.references + templates.insert + templates.list).filter { $0.symbol != nil }
    }()

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile, .inspectorTrackingSeparator, .togglePDF, .toggleInspector]
    }

    /// The default tools, spaces aside, whose widths the workspace reckons Compile's room from.
    var holdsDefaultItems: Bool {
        let tools = { (ids: [NSToolbarItem.Identifier]) in ids.filter { $0 != .space && $0 != .flexibleSpace } }
        return tools(toolbar.itemIdentifiers) == tools(toolbarDefaultItemIdentifiers(toolbar))
    }

    /// To the window's split, not the nested ones, which would answer first, and out of the overflow menu (HIG, Toolbars).
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
        case .undo, .redo:
            let undo = id == .undo
            item = button(id, undo ? "Undo" : "Redo", undo ? "arrow.uturn.backward" : "arrow.uturn.forward",
                          Selector(undo ? "undo:" : "redo:"), help: undo ? "Undo the last change" : "Redo the last undone change")
            // Whatever has the keyboard, as the menu's: it validates them too.
            item.target = nil
        case .format:
            // Notes' words, from its strings (27.2).
            item = button(id, "Format", "textformat", #selector(showFormat(_:)), help: "Choose a style to apply to text")
            let form = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            form.submenu = menu(Group { [app, project] in
                ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                    Button(command.title) { app.perform(command, on: project) }
                }
                Divider()
                SectionLevelItems(project: project)
            })
            item.menuFormRepresentation = form
            item.autovalidates = false
        case .math:
            item = menuItem(id, "Math", "radicand.squareroot",
                            MathMenuItems(project: project) { [app, project] in app.perform(.editMath, on: project) },
                            help: "Insert math or a symbol")
        case .insert:
            item = menuItem(id, "Insert", "plus", InsertMenuItems(project: project), help: "Insert a figure, table, list or reference")
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
            // A word: a play symbol reads as media. Customize Toolbar draws custom views without their style, so a title.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            if flag { item.view = NSHostingView(rootView: compileButton(state)) } else { item.title = MenuCommand.compileRun.title }
            item.style = .prominent
            let form = NSMenuItem(title: MenuCommand.compileRun.title, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
        case .togglePDF:
            item = button(id, "PDF", "richtext.page", #selector(togglePDF), help: "Show or hide the PDF")
        default:
            guard let template = Self.buttonTemplates.first(where: { .template($0) == id }), let symbol = template.symbol else { return nil }
            item = button(id, template.title, symbol, #selector(insertTemplate(_:)), help: "Insert \(template.title.lowercased())")
        }
        // Plain buttons and their overflow copies validate through their targets; other controls follow the models (`configure`).
        if (item.target !== self && ![.undo, .redo].contains(item.itemIdentifier)) || item.view != nil { item.autovalidates = false }
        item.visibilityPriority = [.back, .compile, .togglePDF].contains(id) ? .high : .low
        if flag { configure(item, state) }
        return item
    }

    private static let styles: [NSToolbarItem.Identifier: (MenuCommand, help: String)] = [
        .bold: (.editBold, "Make text bold"), .italic: (.editItalic, "Make text italic"), .underline: (.editUnderline, "Underline text"),
    ]

    /// Its help tag says what it does (HIG, Offering help: not the name again).
    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector, help: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = help
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

    private func zoomItem() -> NSToolbarItem {
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        form.submenu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.hasPDF }) { [app, project, pdf] in
            ForEach([MenuCommand.viewZoomIn, .viewZoomOut], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }.disabled(!app.isEnabled(command, on: project))
            }
            Divider()
            ScaleMenuItems(pdf: pdf)
        })
        let control = ZoomControl()
        control.segmentCount = 3
        control.trackingMode = .momentary
        control.addTarget(self, action: #selector(zoom(_:)), for: .primaryActionTriggered)
        control.setImage(NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out"), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In"), forSegment: 2)
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

    private func menuItem(_ id: NSToolbarItem.Identifier, _ title: String, _ symbol: String, _ items: some View,
                          help: String) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = title
        item.toolTip = help
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.menu = menu(items)
        // No chevrons, as Notes' tools: with them, each menu draws its own capsule (27.2).
        item.showsIndicator = false
        return item
    }

    private func menu(_ items: some View) -> NSMenu {
        NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.isLaTeX }) { items })
    }

    // MARK: - State

    /// Off, all of it, while a project opened over this one loads.
    private nonisolated struct State: Equatable {
        let isLaTeX, hasPDF, canShare, showsPDF: Bool
        let zoomLabel: String
        let canZoomIn, canZoomOut, compiling, canCompile, compactCompile: Bool
    }

    private var state: State {
        let open = !project.closed
        return State(isLaTeX: open && project.isLaTeX, hasPDF: open && project.hasPDF, canShare: open && project.buildPDF != nil,
                     showsPDF: app.showPDF, zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
                     compiling: project.compiling, canCompile: canCompile, compactCompile: compactCompile)
    }

    /// Not a turn later as a `track` would: the toolbar would draw each frame of a sidebar's animation twice.
    private func watch() {
        guard !closed else { return }
        apply(withObservationTracking(options: .didSet) { state } onChange: { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        })
    }

    private func apply(_ state: State) {
        guard !closed else { return }
        for item in toolbar.items { configure(item, state) }
    }

    /// Only what changed: an unchanged label still lays the toolbar out again.
    private func configure(_ item: NSToolbarItem, _ state: State) {
        func update<Root: AnyObject, Value: Equatable>(_ root: Root?, _ key: ReferenceWritableKeyPath<Root, Value>, _ value: Value) {
            if let root, root[keyPath: key] != value { root[keyPath: key] = value }
        }
        switch item.itemIdentifier {
        case .format, .math, .insert:
            update(item, \.isEnabled, state.isLaTeX)
        case .zoom:
            guard let control = item.view as? NSSegmentedControl else { return }
            if control.label(forSegment: 1) != state.zoomLabel { control.setLabel(state.zoomLabel, forSegment: 1) }
            for (segment, enabled) in [state.canZoomOut, true, state.canZoomIn].enumerated()
            where control.isEnabled(forSegment: segment) != (state.hasPDF && enabled) {
                control.setEnabled(state.hasPDF && enabled, forSegment: segment)
            }
            update(item, \.isEnabled, state.hasPDF)
            update(item, \.isHidden, !state.showsPDF)
        case .share:
            update(item, \.isEnabled, state.canShare)
        case .compile:
            let title = (state.compiling ? MenuCommand.compileStop : .compileRun).title
            update(item, \.label, title)
            update(item.menuFormRepresentation, \.title, title)
            // Stop on clear glass: a prominent item's glass stays its own, where a plain item's joins its neighbours'.
            update(item, \.backgroundTintColor, state.compiling ? .clear : nil)
            update(item, \.isEnabled, state.canCompile)
            // A help tag for the symbol alone: the word says as much itself (HIG, Buttons).
            update(item, \.toolTip, !state.compactCompile ? nil : state.compiling ? "Stop the build" : "Compile the project")
            if let host = item.view as? NSHostingView<CompileButton>,
               (host.rootView.compiling, host.rootView.compact, host.rootView.enabled) != (state.compiling, state.compactCompile, state.canCompile) {
                host.rootView = compileButton(state)
            }
        case .togglePDF:
            update(item, \.toolTip, app.title(.viewTogglePDF, on: project))
        default:
            break
        }
    }

    /// The buttons, and their copies in the overflow menu, which AppKit validates through their target.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { allows(item.action) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { allows(menuItem.action) }

    private func allows(_ action: Selector?) -> Bool {
        guard !project.closed else { return false }
        switch action {
        case #selector(style(_:)), #selector(insertTemplate(_:)): return project.isLaTeX
        // The overflow menu's Compile, which the item's own view doesn't enable.
        case #selector(compile): return canCompile
        default: return true
        }
    }

    private var canCompile: Bool { !project.closed && (project.compiling || app.isEnabled(.compileRun, on: project)) }

    // MARK: - Actions

    @objc private func back() { app.perform(.projectClose, on: project) }

    /// A toolbar button's action comes from its item (27.2).
    @objc private func showFormat(_ item: NSToolbarItem) { format.toggle(relativeTo: item) }
    @objc private func style(_ item: NSToolbarItem) { if let (command, _) = Self.styles[item.itemIdentifier] { app.perform(command, on: project) } }
    @objc private func togglePDF() { app.perform(.viewTogglePDF, on: project) }

    @objc private func insertTemplate(_ item: NSToolbarItem) {
        if let template = Self.buttonTemplates.first(where: { .template($0) == item.itemIdentifier }) { project.insert(template) }
    }

    @objc private func zoom(_ control: NSSegmentedControl) {
        if [0, 2].contains(control.selectedSegment) { pdf.zoom(in: control.selectedSegment == 2) }
    }

    @objc private func compile() { app.perform(project.compiling ? .compileStop : .compileRun, on: project) }

    private func compileButton(_ state: State) -> CompileButton {
        CompileButton(compiling: state.compiling, compact: state.compactCompile, enabled: state.canCompile) { [weak self] in self?.compile() }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { project.buildPDF.map { [$0] } ?? [] }
}

/// The menu asks the item, and AppKit's answer for it ignores `isEnabled` (27.2).
private final class ShareItem: NSSharingServicePickerToolbarItem {
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled && super.validateMenuItem(menuItem) }
}

/// The scale's segment keeps the widest label's width, in tabular digits: otherwise the capsule, and the items after it, move.
private final class ZoomControl: NSSegmentedControl {
    var widestLabel = ""
    private var measuredSize: CGFloat?

    override var font: NSFont? {
        get { super.font }
        set { super.font = newValue.map { .monospacedDigitSystemFont(ofSize: $0.pointSize, weight: .regular) } }
    }

    override var controlSize: NSControl.ControlSize { didSet { font = font } }

    /// Inside the toolbar's own update the control's size lags each font change by one (27.2).
    override func layout() {
        super.layout()
        guard let size = font?.pointSize, size != measuredSize else { return }
        measuredSize = size
        let label = label(forSegment: 1) ?? ""
        setLabel(widestLabel, forSegment: 1)
        setWidth(0, forSegment: 1)
        let widest = intrinsicContentSize.width
        setWidth(widest, forSegment: 1)
        setWidth(2 * widest - intrinsicContentSize.width, forSegment: 1)
        setLabel(label, forSegment: 1)
    }
}

/// Stop in Compile's width. It fills the item's glass, which doesn't pass clicks to an undersized view, and changes form
/// as AppKit's search item does (27.2).
private struct CompileButton: View {
    let compiling, compact, enabled: Bool
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Button(action: action) {
            ZStack {
                idle.opacity(compiling ? 0 : 1)
                // A button to VoiceOver still; the status bar says Compiling.
                busy.opacity(compiling ? 1 : 0).accessibilityHidden(true)
            }
            // Faint in a window that isn't the active one, as AppKit's own items.
            .foregroundStyle(appearsActive ? .primary : .tertiary)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2), value: compact)
            // AppKit's glass for a title and for a symbol (27.2).
            .padding(.horizontal, compact ? 0 : 12)
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
    }

    /// At the size AppKit draws an item's symbol (27.2).
    @ViewBuilder private var idle: some View {
        if compact {
            Image(systemName: "play.fill").font(.system(size: 17))
        } else {
            Text(MenuCommand.compileRun.title).transition(.identity)
        }
    }

    /// Round the symbol: the regular spinner touches the circle's edge, and the small one has no room inside.
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

/// The overflow menu still opens the menu, which stays available with its items dimmed (HIG, Menus).
private struct ToolbarMenuItems<Content: View>: View {
    let isEnabled: () -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content().disabled(!isEnabled()) }
}
