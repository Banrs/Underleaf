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
    /// How much less room Compile has than its word takes, which the workspace says with it:
    /// on its way to its symbol it is no wider than the room (`Compression`).
    var compileShort: CGFloat {
        get { fit.short }
        set { if fit.short != newValue { fit.short = newValue } }
    }
    private let fit = Fit()
    @Observable final class Fit {
        var compact = false
        var short: CGFloat = 0
    }
    /// Whether Compile moves between its word and its symbol or is there at once: the workspace
    /// says, as it sets which.
    var animatesCompression = false
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
        // Compile's word is the one label, and the workspace knows its width (`ColumnMetrics`).
        toolbar.allowsDisplayModeCustomization = false
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
            item = menuItem(id, "Math", "radicand.squareroot", mathItems)
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
            // media. It stands for the word only where the word doesn't fit (`CompileButton`).
            // Customize Toolbar gets a title, as it draws custom views without their style.
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            if flag {
                item.view = CompileHost(rootView: compileButton(state))
            } else {
                item.title = MenuCommand.compileRun.title
            }
            // Enabled by `validateMenuItem`, as the button by the models (`configure`).
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
        item.menu = menu(items)
        // No chevrons, as Notes' tools: with them, each menu draws its own capsule (27.2).
        item.showsIndicator = false
        item.visibilityPriority = .low
        return item
    }

    private func menu(_ items: some View) -> NSMenu {
        NSHostingMenu(rootView: ToolbarMenuItems(isEnabled: { [project] in project.isLaTeX }) { items })
    }

    /// Aa opens its popover (`FormatPopover`); the overflow menu has the same as a menu.
    private func formatItem() -> NSToolbarItem {
        let item = button(.format, "Format", "textformat", #selector(showFormat(_:)))
        let form = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        form.image = item.image
        form.submenu = menu(formatItems)
        item.menuFormRepresentation = form
        // Off outside LaTeX, as Math and Insert (`configure`).
        item.autovalidates = false
        item.visibilityPriority = .low
        return item
    }

    /// Format's popover as a menu, for the overflow menu.
    private var formatItems: some View {
        Group { [app, project] in
            ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                Button(command.title) { app.perform(command, on: project) }
            }
            Divider()
            SectionLevelItems(project: project)
        }
    }

    private var mathItems: some View {
        MathMenuItems(project: project) { [app, project] in app.perform(.editMath, on: project) }
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
        let pdfTitle: String
        let compactCompile: Bool
        let compileShort: CGFloat
    }

    private var state: State {
        State(isLaTeX: project.isLaTeX,
              hasPDF: project.hasPDF, canShare: project.buildPDF != nil, showsPDF: app.showPDF,
              zoomLabel: pdf.zoomLabel, canZoomIn: pdf.canZoomIn, canZoomOut: pdf.canZoomOut,
              compiling: project.compiling, canCompile: canCompile,
              pdfTitle: app.title(.viewTogglePdf, on: project), compactCompile: fit.compact, compileShort: fit.short)
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
                item.toolTip = command.title
                item.menuFormRepresentation?.title = command.title
                // Stop on clear glass: still prominent, whose glass stays its own, where a plain
                // item's joins its neighbours'.
                item.backgroundTintColor = state.compiling ? .clear : nil
            }
            if changed(\.canCompile) { item.isEnabled = state.canCompile }
            if changed(\.compiling) || changed(\.compactCompile) || changed(\.compileShort) || changed(\.canCompile) {
                (item.view as? CompileHost)?.show(compileButton(state))
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

    private func compileButton(_ state: State) -> CompileButton {
        CompileButton(compiling: state.compiling, compact: state.compactCompile, short: state.compileShort,
                      enabled: state.canCompile, animated: animatesCompression) { [weak self] in
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

/// Compile's button as the toolbar's item. SwiftUI moves nothing that is in no window: a button
/// taken out of its window on its way from one form to the other would stay as wide as it was,
/// and one AppKit took out for its width, into the overflow menu, would so stay out (27.2). It
/// has its form at once there.
final class CompileHost: NSHostingView<CompileButton> {
    func show(_ button: CompileButton) {
        var button = button
        button.settled = rootView.settled
        rootView = button
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, rootView.animated else { return }
        rootView.animated = false
        rootView.settled += 1
    }
}

/// Compile as its word, or as its symbol where the word has no room, and Stop with the build's
/// spinner in the width Compile has there. It fills the item's glass, which doesn't pass clicks
/// on to an undersized custom view. The word gives way to the symbol, and takes its place back,
/// through the widths between them (`Compression`): the toolbar lays its item out at each, so
/// its glass moves with it. AppKit changes an item's title for its image in one step (27.2).
struct CompileButton: View {
    let compiling: Bool
    let compact: Bool
    /// How much less room there is than the word takes: on its way to its symbol the button is
    /// no wider than its room, or the toolbar would send a tool beside it to the overflow menu
    /// that the symbol leaves room for.
    var short: CGFloat = 0
    let enabled: Bool
    /// Whether a change of form is seen on its way, as with a resize the user is making, or is
    /// there at once, as when a project opens.
    var animated = false
    /// A change of form on its way is dropped for the form itself as this changes (`CompileHost`).
    var settled = 0
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Compression(compact: compact ? 1 : 0, short: compact ? short : 0) {
                word.opacity(compact ? 0 : 1)
                symbol.opacity(compact ? 1 : 0)
            }
            // Nothing of the toolbar's clips its item's view (27.2): the word is cut to the
            // glass's shape as it leaves.
            .clipShape(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(animated && !reduceMotion ? .smooth(duration: 0.25) : nil, value: compact)
        .accessibilityLabel(compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title)
        .id(settled)
    }

    /// As AppKit draws a titled item: 36 points high (the UI kit's toolbar controls), the title
    /// 12 points in from each end, 74 points for Compile (27.2). Stop has the build's spinner
    /// beside it, in Compile's width.
    private var word: some View {
        ZStack {
            idle(Text(MenuCommand.compileRun.title))
            // The button stays a button to VoiceOver; the status bar says Compiling.
            HStack(spacing: 4) {
                spinner(.small, shown: !compact)
                Text(MenuCommand.compileStop.title)
            }
            .opacity(compiling ? 1 : 0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// As AppKit draws an item's symbol: a circle, the symbol at 17 points (27.2). Stop has the
    /// spinner round it: the regular one, 32 points, would touch the circle's edge, and the
    /// small one has no room inside it.
    private var symbol: some View {
        ZStack {
            idle(Image(systemName: "play.fill").font(.system(size: 17)))
            ZStack {
                spinner(.regular, shown: compact).scaleEffect(0.8)
                Image(systemName: "stop.fill").font(.system(size: 7))
            }
            .opacity(compiling ? 1 : 0)
            .accessibilityHidden(true)
        }
        .frame(width: 36, height: 36)
    }

    /// Compile's label, faint in a window that isn't the active one, as AppKit's own prominent item's.
    private func idle(_ label: some View) -> some View {
        label.foregroundStyle(appearsActive ? .primary : .tertiary).opacity(compiling ? 0 : 1)
    }

    /// The spinner's place, and the spinner while a build runs and its form shows: out of sight
    /// it would turn all the same.
    private func spinner(_ size: ControlSize, shown: Bool) -> some View {
        ProgressView().controlSize(size).hidden()
            .overlay { if compiling && shown { ProgressView().controlSize(size) } }
    }
}

/// As wide as its first view, as its last, or between them: `compact` is how far from the first
/// to the last. Animated, it is every width on the way, each a layout of its own, so whatever
/// sizes itself by the view, as a toolbar does its item, follows it there.
struct Compression: Layout {
    var compact: CGFloat
    /// How much less room there is than its first view takes. It is no wider than the room on
    /// its way, nor narrower than its last view: a room closing faster than it moves takes it
    /// along.
    var short: CGFloat = 0

    var animatableData: CGFloat {
        get { compact }
        set { compact = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let first = sizes.first, let last = sizes.last else { return .zero }
        // A spring may pass its end.
        let compact = min(max(compact, 0), 1)
        let width = min(first.width + (last.width - first.width) * compact, first.width - short)
        return CGSize(width: max(width, last.width), height: max(first.height, last.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
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
