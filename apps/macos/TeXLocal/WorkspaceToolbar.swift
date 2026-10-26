import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let format = Self("format")
    static let math = Self("math")
    static let insert = Self("insert")
    static let pdfSeparator = Self("pdfSeparator")
    static let zoom = Self("zoom")
    static let compile = Self("compile")
    static let layout = Self("layout")
    static let share = Self("share")
}

final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSMenuItemValidation {
    let toolbar = NSToolbar(identifier: "Workspace 6")
    var compactCompile = false { didSet { if compactCompile != oldValue { apply(state) } } }
    weak var workspace: WorkspaceController?
    private let app: AppModel
    private let project: ProjectModel
    private var closed = false
    private lazy var format = FormatPopover(app: app, project: project)

    init(app: AppModel, project: ProjectModel) {
        self.app = app
        self.project = project
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = app.savesLayout
        watch()
    }

    func close() {
        closed = true
        format.popover.close()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .format, .math, .insert,
         .pdfSeparator, .flexibleSpace, .zoom, .compile,
         .inspectorTrackingSeparator, .flexibleSpace, .layout, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.share]
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .back, .sidebarTrackingSeparator, .pdfSeparator, .compile, .layout, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem,
              [.toggleSidebar, .toggleInspector].contains(item.itemIdentifier) else { return }
        // Nested split controllers would otherwise receive these actions first.
        item.target = workspace
        item.visibilityPriority = .high
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar inserted: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .back:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = "Back"
            item.toolTip = "Return to Projects"
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(back)
            item.isNavigational = true
        case .format:
            // A button beside the menus shares their glass; the overflow menu has Aa as a menu.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = "Format"
            item.toolTip = "Choose a style to apply to text"
            item.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(showFormat)
            item.menuFormRepresentation = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            item.menuFormRepresentation?.submenu = menu(id, Group { [app, project] in
                ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                    Button(command.title, systemImage: command.style!.symbol) { app.perform(command, on: project) }
                }
                Divider()
                SectionLevelItems(project: project)
            })
        case .math:
            item = menuItem(id, "Math", "radicand.squareroot", MathMenuItems(project: project) { [app, project] in
                app.perform(.editMath, on: project)
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
            if inserted { item.view = NSHostingView(rootView: compileButton(state)) } else { item.title = item.label }
            item.style = .prominent
            let form = NSMenuItem(title: item.label, action: #selector(compile), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
        case .layout:
            item = menuItem(id, "Editor Layout", app.layout.symbol, WorkspaceLayoutPicker(app: app))
            item.toolTip = "Choose Source Only, Source & PDF, or PDF Only"
        case .share:
            let share = ShareItem(itemIdentifier: id)
            share.delegate = self
            share.toolTip = "Share the PDF"
            item = share
        default: return nil
        }
        item.autovalidates = false
        item.visibilityPriority = [.back, .compile, .layout].contains(id) ? .high : .low
        if inserted { configure(item, state) }
        return item
    }

    private func zoomItem() -> NSToolbarItem {
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        form.submenu = NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.hasPDF && !project.closed && !project.isClosing }) { [app, project] in
            ForEach([MenuCommand.viewZoomIn, .viewZoomOut], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }.disabled(!app.isEnabled(command, on: project))
            }
            Divider()
            ScaleMenuItems(pdf: project.pdf)
        })
        let control = ZoomControl()
        control.segmentCount = 3
        control.trackingMode = .momentary
        control.addTarget(self, action: #selector(zoom(_:)), for: .primaryActionTriggered)
        control.setImage(NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out"), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In"), forSegment: 2)
        control.setLabel(project.pdf.zoomLabel, forSegment: 1)
        control.widestLabel = project.pdf.widestZoomLabel
        control.setMenu(NSHostingMenu(rootView: ScaleMenuItems(pdf: project.pdf)), forSegment: 1)
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
        // Adjacent menus share AppKit's glass, as Notes' editing tools do.
        item.showsIndicator = false
        return item
    }

    private func menu(_ id: NSToolbarItem.Identifier, _ content: some View) -> NSMenu {
        NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in
            !project.closed && !project.isClosing && (![.format, .math, .insert].contains(id) || project.sourceToolsEnabled)
        }) { content })
    }

    private struct State {
        let sourceTools, hasPDF, showsPDF, canShare, compiling, canCompile, open: Bool
        let layout: WorkspaceLayout
        let zoomLabel: String
        let canZoomIn, canZoomOut: Bool
    }

    private var state: State {
        State(sourceTools: project.sourceToolsEnabled, hasPDF: project.hasPDF, showsPDF: app.showPDF,
              canShare: project.buildPDF != nil, compiling: project.compiling,
              canCompile: project.compiling || app.isEnabled(.compileRun, on: project), open: !project.closed && !project.isClosing, layout: app.layout,
              zoomLabel: project.pdf.zoomLabel, canZoomIn: project.pdf.canZoomIn, canZoomOut: project.pdf.canZoomOut)
    }

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

    private func configure(_ item: NSToolbarItem, _ state: State) {
        // Setting an unchanged property can restart a toolbar layout during a split animation.
        func update<Root: AnyObject, Value: Equatable>(_ root: Root?, _ key: ReferenceWritableKeyPath<Root, Value>, _ value: Value) {
            if let root, root[keyPath: key] != value { root[keyPath: key] = value }
        }
        switch item.itemIdentifier {
        case .format, .math, .insert:
            // Hidden with the source; dimmed for a file they don't apply to, where hiding would move their neighbours.
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
            update(item, \.isHidden, !state.showsPDF)
        case .share:
            update(item, \.isEnabled, state.open && state.canShare)
        case .compile:
            let title = (state.compiling ? MenuCommand.compileStop : .compileRun).title
            update(item, \.label, title)
            update(item.menuFormRepresentation, \.title, title)
            update(item, \.backgroundTintColor, state.compiling ? .clear : nil)
            update(item, \.isEnabled, state.open && state.canCompile)
            update(item, \.toolTip, compactCompile ? state.compiling ? "Stop the build" : "Compile the project" : nil)
            if let host = item.view as? NSHostingView<CompileButton>,
               (host.rootView.compiling, host.rootView.compact, host.rootView.enabled) != (state.compiling, compactCompile, state.open && state.canCompile) {
                host.rootView = compileButton(state)
            }
        case .layout:
            update(item, \.isEnabled, state.open)
            if item.image?.accessibilityDescription != state.layout.title {
                item.image = NSImage(systemSymbolName: state.layout.symbol, accessibilityDescription: state.layout.title)
            }
        default: update(item, \.isEnabled, state.open)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { !project.closed && !project.isClosing && (item.action != #selector(compile) || state.canCompile) }
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { project.buildPDF.map { [$0] } ?? [] }
    @objc private func showFormat(_ item: NSToolbarItem) { format.toggle(relativeTo: item) }
    @objc private func zoom(_ control: NSSegmentedControl) {
        if [0, 2].contains(control.selectedSegment) { project.pdf.zoom(in: control.selectedSegment == 2) }
    }
    @objc private func back() { app.perform(.projectClose, on: project) }
    @objc private func compile() { app.perform(project.compiling ? .compileStop : .compileRun, on: project) }

    private func compileButton(_ state: State) -> CompileButton {
        CompileButton(compiling: state.compiling, compact: compactCompile, enabled: state.open && state.canCompile) { [weak self] in self?.compile() }
    }
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
        case .source: "rectangle.lefthalf.inset.filled"
        case .split: "rectangle.split.2x1"
        case .pdf: "rectangle.righthalf.inset.filled"
        }
    }
}

struct WorkspaceLayoutPicker: View {
    @Bindable var app: AppModel

    var body: some View {
        Picker("Editor Layout", selection: $app.layout) {
            ForEach([WorkspaceLayout.source, .split, .pdf], id: \.self) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
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

    /// Inside the toolbar's own update the control's size lags each font change by one
    /// (`theToolbarsControlsKeepTheirStateAndWidth`).
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

/// Stop in Compile's width, as its word and as its symbol, so the tools beside it stay put. It fills the item's glass,
/// which passes no clicks to an undersized view, and changes form as AppKit's search item does.
private struct CompileButton: View {
    let compiling, compact, enabled: Bool
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                idle.opacity(compiling ? 0 : 1)
                // A button to VoiceOver still; the status bar says Compiling.
                busy.opacity(compiling ? 1 : 0).accessibilityHidden(true)
            }
            // Faint in a window that isn't the active one, as AppKit's own items.
            .foregroundStyle(appearsActive ? .primary : .tertiary)
            .animation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2), value: compact)
            // The padding and height of AppKit's glass around an item's title, and its circle around a symbol.
            .padding(.horizontal, compact ? 0 : 12)
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
    }

    /// At the size AppKit draws an item's symbol.
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

private struct ToolbarMenuItems<Content: View>: View {
    let isEnabled: () -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content().disabled(!isEnabled()) }
}

private final class ShareItem: NSSharingServicePickerToolbarItem {
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled && super.validateMenuItem(menuItem) }
}

