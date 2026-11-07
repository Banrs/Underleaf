import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let navigation = Self("navigation")
    static let format = Self("format")
    static let math = Self("math")
    static let insert = Self("insert")
    static let pdfSeparator = Self("pdfSeparator")
    static let zoom = Self("zoom")
    static let compile = Self("compile")
    static let layout = Self("layout")
    static let inspector = Self("inspector")
    static let share = Self("share")
}

final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSMenuItemValidation {
    let toolbar = NSToolbar(identifier: "Workspace 8")
    private(set) var compactCompile = false
    weak var workspace: WorkspaceController?
    private let window: WindowModel
    private let views: WorkspaceViews
    private var project: ProjectModel { views.project }
    private var pdf: PDFController { views.pdf }
    private var watch: Task<Void, Never>?
    private lazy var compileButton = CompileButton(target: self, action: #selector(compile))
    private var compileItem: NSToolbarItem?
    private var overflow: NSKeyValueObservation?
    private var wideRoom: CGFloat = 0
    private var applied: State?

    init(window: WindowModel, views: WorkspaceViews) {
        self.window = window
        self.views = views
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = window.app.savesLayout
        watch = track({ [weak self] in self?.state }) { [weak self] in if let state = $0 { self?.apply(state) } }
    }

    func close() {
        watch?.cancel()
        overflow?.invalidate()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .navigation, .flexibleSpace, .format, .math, .insert,
         .pdfSeparator, .flexibleSpace, .zoom, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .layout, .inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.share]
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .navigation, .pdfSeparator, .compile, .layout, .inspectorTrackingSeparator, .inspector]
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem,
              item.itemIdentifier == .toggleSidebar else { return }
        item.visibilityPriority = .high
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar inserted: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .navigation:
            item = navigationItem()
        case .format:
            item = menuItem(id, "Format", "textformat", Group { [window, views] in
                ControlGroup {
                    let styles = [(MenuCommand.editBold, \TextStyles.bold), (.editItalic, \.italic), (.editUnderline, \.underline)]
                    ForEach(styles, id: \.0) { command, style in
                        let on = Binding(get: { views.textStyles[keyPath: style] != nil }, set: { _ in window.perform(command, on: views.project) })
                        Toggle(command.title, systemImage: command.style!.symbol, isOn: on).help(command.style!.help)
                    }
                }
                .controlGroupStyle(.palette)
                Divider()
                SectionLevelItems(project: views.project)
            })
            item.toolTip = "Choose a style to apply to text"
        case .math:
            item = menuItem(id, "Math", "radicand.squareroot", Group { [window, project] in
                MathMenuItems(project: project) { window.perform(.editMath, on: project) }
                Divider()
                Button(MenuCommand.symbolLibrary.title) { window.perform(.symbolLibrary, on: project) }
            })
        case .insert:
            item = menuItem(id, "Insert", "plus", InsertMenuItems(project: project))
        case .pdfSeparator:
            guard let split = workspace?.columns.splitView else { return nil }
            item = NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case .zoom:
            item = zoomItem()
        case .compile:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            if inserted { watchOverflow(of: item) } else { item.title = item.label }
            let form = NSMenuItem(title: item.label, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
        case .layout:
            item = menuItem(id, "Editor Layout", window.layout.symbol, WorkspaceLayoutPicker(window: window))
            item.toolTip = "Choose Source Only, Source & PDF, or PDF Only"
        case .inspector:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.viewToggleInspector.title
            item.toolTip = "Show or hide the inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: item.label)
            item.action = #selector(NSSplitViewController.toggleInspector(_:))
        case .share:
            let share = ShareItem(itemIdentifier: id)
            share.delegate = self
            share.toolTip = "Share the PDF"
            item = share
        default: return nil
        }
        item.autovalidates = false
        // Back and Forward stay in their menus and their keys, so they give way before a compact Compile in a narrow window.
        item.visibilityPriority = id == .compile ? compilePriority : id == .navigation ? .standard
            : [.layout, .inspector].contains(id) ? .high : .low
        if inserted { configure(item, state) }
        return item
    }

    /// Xcode 27.2's ‹ › before the title, in its words (read from its accessibility): a momentary pair that AppKit places
    /// before the title as a navigational item, retracing the places the caret has been, as Navigate ▸ Go Back and Go Forward do.
    private func navigationItem() -> NSToolbarItem {
        let commands = [MenuCommand.goBack, .goForward]
        let images = zip(commands, ["chevron.left", "chevron.right"]).compactMap { command, symbol in
            NSImage(systemSymbolName: symbol, accessibilityDescription: command.title)
        }
        let group = NSToolbarItemGroup(itemIdentifier: .navigation, images: images, selectionMode: .momentary,
                                       labels: commands.map(\.title), target: self, action: #selector(retrace(_:)))
        group.isNavigational = true
        group.label = String(localized: "Back/Forward")
        group.controlRepresentation = .expanded
        for (subitem, help) in zip(group.subitems, [String(localized: "Show Previous Location in History"),
                                                    String(localized: "Show Next Location in History")]) {
            subitem.toolTip = help
            subitem.autovalidates = false
        }
        let form = NSMenuItem(title: group.label, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (command, action) in zip(commands, [#selector(goBack), #selector(goForward)]) {
            menu.addItem(withTitle: command.title, action: action, keyEquivalent: "").target = self
        }
        form.submenu = menu
        group.menuFormRepresentation = form
        return group
    }

    private func zoomItem() -> NSToolbarItem {
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        form.submenu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.hasPDF && project.isOpen }) { [window, project, pdf] in
            ForEach([MenuCommand.viewZoomIn, .viewZoomOut], id: \.self) { command in
                Button(command.title) { window.perform(command, on: project) }.disabled(!window.app.isEnabled(command, on: project))
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

    private func menuItem(_ id: NSToolbarItem.Identifier, _ title: String, _ symbol: String, _ content: some View) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.menu = menu(id, content)
        item.showsIndicator = false
        return item
    }

    private func menu(_ id: NSToolbarItem.Identifier, _ content: some View) -> NSMenu {
        NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in
            project.isOpen && (![.format, .math, .insert].contains(id) || project.sourceToolsEnabled)
        }) { content })
    }

    private nonisolated struct State: Equatable {
        let sourceTools, hasPDF, canShare, compiling, canCompile, open: Bool
        let layout: WorkspaceLayout
        let zoomLabel: String
        let canZoomIn, canZoomOut, canGoBack, canGoForward: Bool
    }

    private var state: State {
        State(sourceTools: project.sourceToolsEnabled, hasPDF: project.hasPDF, canShare: project.buildPDF != nil, compiling: project.compiling,
              canCompile: project.compiling || window.app.isEnabled(.compileRun, on: project), open: project.isOpen, layout: window.layout,
              zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
              canGoBack: window.app.isEnabled(.goBack, on: project), canGoForward: window.app.isEnabled(.goForward, on: project))
    }

    private func apply(_ state: State) {
        if compactCompile, let applied, applied.layout != state.layout { compactCompile = false }
        applied = state
        for item in toolbar.items { configure(item, state) }
    }

    private var compilePriority: NSToolbarItem.VisibilityPriority {
        compactCompile ? .high : NSToolbarItem.VisibilityPriority(rawValue: NSToolbarItem.VisibilityPriority.low.rawValue - 1)
    }

    private func watchOverflow(of item: NSToolbarItem) {
        item.view = compileButton
        compileItem = item
        overflow = item.observe(\.isVisible, options: .initial) { [weak self] item, _ in MainActor.assumeIsolated { self?.overflowed(item) } }
    }

    /// AppKit can move the item to the overflow menu for a moment while a resize settles, so it's read again once layout is done.
    private func overflowed(_ item: NSToolbarItem) {
        guard !item.isVisible, !compactCompile else { return }
        Task { [weak self] in
            guard let self, !item.isVisible, !compactCompile, toolbar.isVisible, let room = workspace?.toolbarRoom else { return }
            wideRoom = room + compileButton.intrinsicContentSize.width
            setCompact(true)
        }
    }

    @objc func fit() {
        guard compactCompile, let room = workspace?.toolbarRoom, room + compileButton.intrinsicContentSize.width >= wideRoom else { return }
        setCompact(false)
    }

    private func setCompact(_ compact: Bool) {
        compactCompile = compact
        if let compileItem { configure(compileItem, state) }
    }

    private func configure(_ item: NSToolbarItem, _ state: State) {
        func update<Root: AnyObject, Value: Equatable>(_ root: Root?, _ key: ReferenceWritableKeyPath<Root, Value>, _ value: Value) {
            if let root, root[keyPath: key] != value { root[keyPath: key] = value }
        }
        switch item.itemIdentifier {
        case .navigation:
            update(item, \.isEnabled, state.open)
            guard let group = item as? NSToolbarItemGroup else { return }
            for (subitem, enabled) in zip(group.subitems, [state.canGoBack, state.canGoForward]) {
                update(subitem, \.isEnabled, state.open && enabled)
            }
        case .format, .math, .insert:
            update(item, \.isHidden, state.layout == .pdf)
            update(item, \.isEnabled, state.open && state.sourceTools)
        case .pdfSeparator:
            update(item, \.isHidden, state.layout != .split)
        case .zoom:
            guard let control = item.view as? NSSegmentedControl else { return }
            let shown = state.open && state.hasPDF
            if control.label(forSegment: 1) != state.zoomLabel { control.setLabel(state.zoomLabel, forSegment: 1) }
            for (segment, enabled) in [state.canZoomOut, true, state.canZoomIn].enumerated()
            where control.isEnabled(forSegment: segment) != (shown && enabled) {
                control.setEnabled(shown && enabled, forSegment: segment)
            }
            update(item, \.isEnabled, shown)
            update(item, \.isHidden, state.layout == .source)
        case .share:
            update(item, \.isEnabled, state.open && state.canShare)
        case .compile:
            let title = (state.compiling ? MenuCommand.compileStop : .compileRun).title
            update(item, \.label, title)
            update(item.menuFormRepresentation, \.title, title)
            update(item, \.style, state.compiling ? .plain : .prominent)
            update(item, \.isEnabled, state.open && state.canCompile)
            update(item, \.visibilityPriority, compilePriority)
            guard item.view === compileButton else { return }
            update(compileButton, \.isEnabled, state.open && state.canCompile)
            update(compileButton, \.toolTip, compactCompile ? state.compiling ? "Stop the build" : "Compile the project" : nil)
            compileButton.show(compiling: state.compiling, compact: compactCompile)
        case .layout:
            update(item, \.isEnabled, state.open)
            if item.image?.accessibilityDescription != state.layout.title {
                item.image = NSImage(systemSymbolName: state.layout.symbol, accessibilityDescription: state.layout.title)
            }
        default: update(item, \.isEnabled, state.open)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(compile): project.isOpen && state.canCompile
        case #selector(goBack): project.isOpen && state.canGoBack
        case #selector(goForward): project.isOpen && state.canGoForward
        default: project.isOpen
        }
    }
    @objc private func retrace(_ group: NSToolbarItemGroup) { window.perform(group.selectedIndex == 0 ? .goBack : .goForward, on: project) }
    @objc private func goBack() { window.perform(.goBack, on: project) }
    @objc private func goForward() { window.perform(.goForward, on: project) }
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { project.buildPDF.map { [$0] } ?? [] }
    @objc private func zoom(_ control: NSSegmentedControl) {
        if [0, 2].contains(control.selectedSegment) { pdf.zoom(in: control.selectedSegment == 2) }
    }
    @objc private func compile() { window.perform(project.compiling ? .compileStop : .compileRun, on: project) }
}

extension WorkspaceLayout {
    var title: String {
        switch self {
        case .source: String(localized: "Source Only")
        case .split: String(localized: "Source & PDF")
        case .pdf: String(localized: "PDF Only")
        }
    }

    var symbol: String {
        switch self {
        case .source: "rectangle.leadinghalf.inset.filled"
        case .split: "rectangle.split.2x1"
        case .pdf: "rectangle.trailinghalf.inset.filled"
        }
    }
}

struct WorkspaceLayoutPicker: View {
    @Bindable var window: WindowModel

    var body: some View {
        Picker("Editor Layout", selection: $window.layout) {
            ForEach([WorkspaceLayout.source, .split, .pdf], id: \.self) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

private final class ZoomControl: NSSegmentedControl {
    var widestLabel = ""
    private var measuredSize: CGFloat?

    override var font: NSFont? {
        get { super.font }
        set { super.font = newValue.map { .monospacedDigitSystemFont(ofSize: $0.pointSize, weight: .regular) } }
    }

    override var controlSize: NSControl.ControlSize { didSet { font = font } }

    /// A fixed segment width leaves out the padding AppKit adds around a label, so the padding and the other segments (`rest`)
    /// are read as the control's width with the segment fixed at some width, less that width.
    override func layout() {
        super.layout()
        guard let size = font?.pointSize, size != measuredSize else { return }
        measuredSize = size
        let label = label(forSegment: 1) ?? ""
        setLabel(widestLabel, forSegment: 1)
        setWidth(0, forSegment: 1)
        let fitted = intrinsicContentSize.width
        setWidth(fitted, forSegment: 1)
        let rest = intrinsicContentSize.width - fitted
        setWidth(fitted - rest, forSegment: 1)
        setLabel(label, forSegment: 1)
    }
}

private final class CompileButton: NSButton {
    private let spinner = NSProgressIndicator()
    private var widest: CGFloat = 0
    private var shown: (compiling: Bool, compact: Bool)?

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        (self.target, self.action) = (target, action)
        bezelStyle = .toolbar
        imagePosition = .imageLeading
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(compiling: Bool, compact: Bool) {
        guard shown.map({ $0 != (compiling, compact) }) ?? true else { return }
        shown = (compiling, compact)
        let command = compiling ? MenuCommand.compileStop : .compileRun
        title = compact ? "" : command.title
        spinner.controlSize = compact ? .regular : .small
        image = switch (compact, compiling) {
        case (true, _): NSImage(systemSymbolName: compiling ? "stop.fill" : "play.fill", accessibilityDescription: command.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(scale: compiling ? .small : .medium))
        case (false, true): NSImage(size: spinner.intrinsicContentSize)
        case (false, false): nil
        }
        if compiling { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        guard !title.isEmpty else { return size }
        widest = max(widest, size.width)
        size.width = widest
        return size
    }

    override func layout() {
        super.layout()
        let well = title.isEmpty ? bounds : cell?.imageRect(forBounds: bounds) ?? bounds, size = spinner.intrinsicContentSize
        spinner.frame = NSRect(x: (well.midX - size.width / 2).rounded(), y: (well.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
}

private struct ToolbarMenuItems<Content: View>: View {
    let isEnabled: () -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content().disabled(!isEnabled()) }
}

private final class ShareItem: NSSharingServicePickerToolbarItem {
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled && super.validateMenuItem(menuItem) }
}
