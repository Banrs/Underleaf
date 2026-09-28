import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let undoRedo = Self("undoRedo")
    static let sectionLevel = Self("sectionLevel")
    static let format = Self("format")
    static let math = Self("math")
    static let references = Self("references")
    static let figures = Self("figures")
    static let lists = Self("lists")
    static let insert = Self("insert")
    /// The source/PDF divider's line through the toolbar.
    static let pdfSeparator = Self("pdfSeparator")
    static let zoom = Self("zoom")
    static let share = Self("share")
    static let freshness = Self("freshness")
    static let projectSettings = Self("projectSettings")
    static let compile = Self("compile")
    static let togglePDF = Self("togglePDF")
}

/// The project window's toolbar, AppKit's so each column's tools sit over it:
/// the sidebar toggle over the sidebar; back, the title and the source's tools over
/// the source; the PDF's and the build's over the PDF, from the source/PDF divider,
/// whose line runs through the toolbar (`NSTrackingSeparatorToolbarItem`). A hidden
/// PDF's tools move over the source by themselves. Short of room, zoom and Share go
/// to the overflow menu first, Compile and the PDF toggle last (HIG, Toolbars: few,
/// frequent, grouped by task); Customize Toolbar adds the rest.
final class WorkspaceToolbar: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate,
                              NSPopoverDelegate, NSMenuDelegate {
    let toolbar = NSToolbar(identifier: "Workspace")
    private let app: AppModel
    private let project: ProjectModel
    private let pdf: PDFController
    private weak var workspace: WorkspaceController?
    private var watches: [Task<Void, Never>] = []
    private var settings: NSPopover?

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
        watches = [
            track({ [weak self] in self?.state }) { [weak self] state in
                if let state { self?.apply(state) }
            },
            track({ [app] in app.showProjectSettings }) { [weak self] shown in self?.showSettings(shown) },
        ]
    }

    func close() {
        watches.forEach { $0.cancel() }
        settings?.close()
    }

    // ---------- items ----------

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .flexibleSpace, .format, .insert,
         .pdfSeparator, .zoom, .share, .flexibleSpace, .freshness, .projectSettings, .compile, .togglePDF]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
            + [.undoRedo, .sectionLevel, .math, .references, .figures, .lists, .space, .flexibleSpace]
    }

    /// The window's own: the way back, the build and the columns.
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .pdfSeparator, .compile, .togglePDF]
    }

    /// The system's sidebar toggle sends `toggleSidebar:` down the responder chain,
    /// where the columns' own split view controllers, which have no sidebar, would
    /// answer first: it goes to the window's split.
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
            // Before the title (HIG, Toolbars: back leads). One level, no history to go forward.
            item.isNavigational = true
        case .undoRedo:
            item = segments(id, "Undo and Redo", [(MenuCommand.editUndo.title, "arrow.uturn.backward"),
                                                 (MenuCommand.editRedo.title, "arrow.uturn.forward")], #selector(undoRedo(_:)))
            item.visibilityPriority = .low
        case .sectionLevel:
            item = sectionLevelItem()
        case .format:
            item = segments(id, "Format", [(MenuCommand.editBold.title, "bold"), (MenuCommand.editItalic.title, "italic")],
                            #selector(formatText(_:)))
        case .math:
            item = mathItem()
            item.visibilityPriority = .low
        case .references:
            item = templates(id, "References", referenceTemplates)
        case .figures:
            item = templates(id, "Figures and Tables", insertTemplates)
        case .lists:
            item = templates(id, "Lists", listTemplates)
        case .insert:
            let menu = NSMenuToolbarItem(itemIdentifier: id)
            menu.image = symbol("plus", "Insert")
            menu.label = "Insert"
            menu.toolTip = "Insert"
            menu.menu = insertMenu()
            item = menu
        case .pdfSeparator:
            guard let split = workspace?.columns.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case .zoom:
            item = zoomItem()
            item.visibilityPriority = .low
        case .share:
            let share = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            share.delegate = self
            share.label = "Share"
            share.toolTip = "Share PDF"
            share.visibilityPriority = .low
            item = share
        case .freshness:
            item = button(id, "Preview Status", "clock.arrow.circlepath", #selector(freshness))
        case .projectSettings:
            item = button(id, "Project Settings", "info.circle", #selector(toggleSettings))
        case .compile:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = MenuCommand.compileRun.title
            item.title = MenuCommand.compileRun.title
            item.target = self
            item.action = #selector(compile)
            // Its word, not a lone play symbol, which reads as media; the one
            // prominent control, on glass of its own.
            item.style = .prominent
            item.visibilityPriority = .high
        case .togglePDF:
            // A document's symbol: the PDF is the source's peer, not a sidebar or an inspector.
            item = button(id, "PDF", "doc.richtext", #selector(togglePDF))
            item.visibilityPriority = .high
        default:
            return nil
        }
        // Their state is the models' (`apply`), not validation's, which would turn
        // on any item whose target answers its action.
        item.autovalidates = false
        (item as? NSToolbarItemGroup)?.subitems.forEach { $0.autovalidates = false }
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

    /// The UI kit's segmented toolbar control: one capsule, a line between segments.
    private func segments(_ id: NSToolbarItem.Identifier, _ label: String, _ parts: [(title: String, symbol: String)],
                          _ action: Selector) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id, images: parts.compactMap { symbol($0.symbol, $0.title) },
                                       selectionMode: .momentary, labels: parts.map(\.title), target: self, action: action)
        group.label = label
        group.controlRepresentation = .expanded
        for (subitem, part) in zip(group.subitems, parts) { subitem.toolTip = part.title }
        return group
    }

    /// A segment per template with a symbol; the rest are in the Insert menu.
    private func templates(_ id: NSToolbarItem.Identifier, _ label: String, _ templates: [Template]) -> NSToolbarItemGroup {
        let shown = templates.filter { $0.symbol != nil }
        let group = segments(id, label, shown.map { ($0.title, $0.symbol ?? "") }, #selector(insertTemplate(_:)))
        group.visibilityPriority = .low
        return group
    }

    /// Inline Math | Symbols: a segmented control whose second segment opens its menu.
    private func mathItem() -> NSToolbarItem {
        let control = NSSegmentedControl(images: [symbol("x.squareroot", MenuCommand.editMath.title),
                                                  symbol("sum", "Symbols")].compactMap(\.self),
                                         trackingMode: .momentary, target: self, action: #selector(math(_:)))
        control.setToolTip(MenuCommand.editMath.title, forSegment: 0)
        control.setToolTip("Symbols", forSegment: 1)
        control.setMenu(symbolsMenu(), forSegment: 1)
        control.setShowsMenuIndicator(true, forSegment: 1)
        let group = NSToolbarItemGroup(itemIdentifier: .math)
        group.label = "Math"
        group.subitems = [MenuCommand.editMath.title, "Symbols"].map { title in
            let subitem = NSToolbarItem(itemIdentifier: .init(title))
            subitem.label = title
            return subitem
        }
        group.view = control
        let form = NSMenuItem(title: "Math", action: nil, keyEquivalent: "")
        form.submenu = NSMenu(title: "Math")
        form.submenu?.addItem(menuItem(MenuCommand.editMath.title) { [weak self] in self?.perform(.editMath) })
        form.submenu?.addItem(submenu("Symbols", symbolsMenu()))
        group.menuFormRepresentation = form
        return group
    }

    /// Zoom out | the scale | zoom in, one capsule; the scale opens a menu of fits and
    /// presets (View has the same commands with their shortcuts). While fitting, no
    /// preset is checked.
    private func zoomItem() -> NSToolbarItem {
        let control = NSSegmentedControl(images: [symbol("minus.magnifyingglass", "Zoom Out"), NSImage(),
                                                  symbol("plus.magnifyingglass", "Zoom In")].compactMap(\.self),
                                         trackingMode: .momentary, target: self, action: #selector(zoom(_:)))
        control.setImage(nil, forSegment: 1)
        control.setLabel(pdf.zoomLabel, forSegment: 1)
        control.setToolTip("Zoom Out", forSegment: 0)
        control.setToolTip("Scale", forSegment: 1)
        control.setToolTip("Zoom In", forSegment: 2)
        control.setMenu(scaleMenu(), forSegment: 1)
        control.setShowsMenuIndicator(true, forSegment: 1)
        control.setAccessibilityLabel("Zoom")
        let group = NSToolbarItemGroup(itemIdentifier: .zoom)
        group.label = "Zoom"
        group.subitems = ["Zoom Out", "Scale", "Zoom In"].map { title in
            let subitem = NSToolbarItem(itemIdentifier: .init(title))
            subitem.label = title
            return subitem
        }
        group.view = control
        // In the overflow menu: a Zoom submenu.
        let form = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let menu = scaleMenu()
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(menuItem("Zoom Out") { [weak self] in self?.pdf.zoom(in: false) }, at: 0)
        menu.insertItem(menuItem("Zoom In") { [weak self] in self?.pdf.zoom(in: true) }, at: 0)
        form.submenu = menu
        group.menuFormRepresentation = form
        return group
    }

    private func scaleMenu() -> NSMenu {
        let menu = NSMenu(title: "Scale")
        menu.delegate = self
        menu.addItem(menuItem("Fit Width", tag: ScaleTag.fitWidth) { [weak self] in self?.pdf.fitWidth() })
        menu.addItem(menuItem("Fit Height", tag: ScaleTag.fitHeight) { [weak self] in self?.pdf.fitHeight() })
        menu.addItem(.separator())
        for percent in Self.zoomPresets {
            menu.addItem(menuItem((Double(percent) / 100).formatted(.percent), tag: percent) { [weak self] in
                self?.pdf.setScale(CGFloat(percent) / 100)
            })
        }
        return menu
    }

    private static let zoomPresets = [50, 75, 100, 125, 150, 200]
    private enum ScaleTag { static let fitWidth = -1, fitHeight = -2 }

    /// The caret line's section level; choosing one makes the line that heading.
    private func sectionLevelItem() -> NSToolbarItem {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for level in HeadingLevel.all {
            popUp.addItem(withTitle: level.title)
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
        form.submenu = NSMenu(title: "Section Level")
        for level in HeadingLevel.all {
            form.submenu?.addItem(menuItem(level.title) { [weak self] in
                self?.project.format(.heading, level.command)
            })
        }
        item.menuFormRepresentation = form
        return item
    }

    /// The Insert menu's items; the section level is Format's, a style.
    private func insertMenu() -> NSMenu {
        let menu = NSMenu(title: "Insert")
        menu.addItem(menuItem(MenuCommand.editMath.title) { [weak self] in self?.perform(.editMath) })
        menu.addItem(menuItem("Display Math") { [weak self] in self?.project.format(.displayMath) })
        menu.addItem(submenu("Symbols", symbolsMenu()))
        menu.addItem(submenu("Reference", templatesMenu(referenceTemplates)))
        menu.addItem(.separator())
        for template in insertTemplates {
            menu.addItem(menuItem(template.title) { [weak self] in self?.project.insert(template) })
        }
        menu.addItem(submenu("List", templatesMenu(listTemplates)))
        return menu
    }

    private func templatesMenu(_ templates: [Template]) -> NSMenu {
        let menu = NSMenu()
        for template in templates {
            menu.addItem(menuItem(template.title) { [weak self] in self?.project.insert(template) })
        }
        return menu
    }

    /// The symbols by kind, each kind a submenu; the glyph over its command.
    private func symbolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Symbols")
        for (kind, symbols) in symbolGroups {
            let kindMenu = NSMenu(title: kind)
            for (glyph, command) in symbols {
                let item = menuItem(glyph) { [weak self] in self?.project.format(.symbol, command) }
                item.subtitle = command
                kindMenu.addItem(item)
            }
            menu.addItem(submenu(kind, kindMenu))
        }
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    // ---------- state ----------

    /// What the items show, read from the models; a change redraws them.
    private nonisolated struct State: Equatable {
        var editsText = false
        var isLaTeX = false
        var canUndo = false
        var sectionLevel = 0
        var hasPDF = false
        var showsPDF = true
        var zoomLabel = ""
        var canZoomIn = false
        var canZoomOut = false
        var compiling = false
        var canCompile = false
        var freshness: PDFFreshness?
        var pdfTitle = ""
    }

    private var state: State {
        var state = State()
        state.editsText = project.editsText
        state.isLaTeX = project.isLaTeX
        state.canUndo = project.openPath == nil || project.editsText
        let current = project.outline.first { $0.line == project.cursorLine }
            .flatMap { HeadingLevel.atDepth($0.level) } ?? .normalText
        state.sectionLevel = HeadingLevel.all.firstIndex(of: current) ?? 0
        state.hasPDF = project.hasPDF
        state.showsPDF = project.showPDF
        state.zoomLabel = pdf.zoomLabel
        state.canZoomIn = pdf.canZoomIn
        state.canZoomOut = pdf.canZoomOut
        state.compiling = project.compiling
        state.canCompile = app.isEnabled(.compileRun, on: project)
        state.freshness = project.hasPDF ? project.pdfFreshness : nil
        state.pdfTitle = app.title(.viewTogglePdf, on: project)
        return state
    }

    private func apply(_ state: State) {
        for item in toolbar.items { configure(item, state) }
    }

    private func configure(_ item: NSToolbarItem, _ state: State) {
        switch item.itemIdentifier {
        case .undoRedo:
            enable(item, state.canUndo)
        case .format, .references, .figures, .lists, .insert:
            enable(item, state.isLaTeX)
        case .math:
            enable(item, state.isLaTeX)
            (item.view as? NSSegmentedControl)?.isEnabled = state.isLaTeX
        case .sectionLevel:
            let popUp = item.view as? NSPopUpButton
            popUp?.isEnabled = state.isLaTeX
            // Past the separator, the menu's items are one further on.
            popUp?.selectItem(at: state.sectionLevel == 0 ? 0 : state.sectionLevel + 1)
            item.isEnabled = state.isLaTeX
        case .zoom:
            let control = item.view as? NSSegmentedControl
            control?.setLabel(state.zoomLabel, forSegment: 1)
            control?.setEnabled(state.hasPDF && state.canZoomOut, forSegment: 0)
            control?.setEnabled(state.hasPDF, forSegment: 1)
            control?.setEnabled(state.hasPDF && state.canZoomIn, forSegment: 2)
            item.isEnabled = state.hasPDF
            // Only for the pages on screen.
            item.isHidden = !state.showsPDF
        case .share:
            item.isEnabled = state.hasPDF
        case .freshness:
            item.isHidden = state.freshness == nil
            if let freshness = state.freshness {
                item.image = symbol(freshness.systemImage, freshness.title)
                item.label = freshness.title
                item.toolTip = freshness == .lastSuccessful
                    ? "The latest build failed; this is the last one that succeeded. Show Issues"
                    : "The preview doesn’t reflect the current source. Compile"
            }
        case .compile:
            // Stop in its place while a build runs.
            let title = state.compiling ? MenuCommand.compileStop.title : MenuCommand.compileRun.title
            item.title = title
            item.label = title
            item.toolTip = title
            item.style = state.compiling ? .plain : .prominent
            item.isEnabled = state.compiling || state.canCompile
        case .togglePDF:
            item.label = state.pdfTitle
            item.toolTip = state.pdfTitle
        default:
            break
        }
    }

    private func enable(_ item: NSToolbarItem, _ enabled: Bool) {
        item.isEnabled = enabled
        (item as? NSToolbarItemGroup)?.subitems.forEach { $0.isEnabled = enabled }
    }

    // ---------- actions ----------

    private func perform(_ command: MenuCommand) {
        app.perform(command, on: project)
    }

    @objc private func back() { perform(.projectClose) }

    @objc private func undoRedo(_ group: NSToolbarItemGroup) {
        perform(group.selectedIndex == 0 ? .editUndo : .editRedo)
    }

    @objc private func formatText(_ group: NSToolbarItemGroup) {
        perform(group.selectedIndex == 0 ? .editBold : .editItalic)
    }

    @objc private func insertTemplate(_ group: NSToolbarItemGroup) {
        let all = [referenceTemplates, insertTemplates, listTemplates].flatMap { $0 }.filter { $0.symbol != nil }
        let titles = group.subitems.map(\.label)
        guard titles.indices.contains(group.selectedIndex),
              let template = all.first(where: { $0.title == titles[group.selectedIndex] }) else { return }
        project.insert(template)
    }

    /// The Symbols segment opens its menu itself.
    @objc private func math(_ control: NSSegmentedControl) {
        if control.selectedSegment == 0 { perform(.editMath) }
    }

    /// The scale segment opens its menu itself.
    @objc private func zoom(_ control: NSSegmentedControl) {
        switch control.selectedSegment {
        case 0: pdf.zoom(in: false)
        case 2: pdf.zoom(in: true)
        default: break
        }
    }

    @objc private func sectionLevel(_ popUp: NSPopUpButton) {
        let index = popUp.indexOfSelectedItem
        let levels = HeadingLevel.all
        let level = index == 0 ? levels[0] : levels[min(index - 1, levels.count - 1)]
        project.format(.heading, level.command)
    }

    @objc private func freshness() {
        if project.pdfFreshness == .edited { perform(.compileRun) } else { project.showBuildPanel() }
    }

    @objc private func compile() {
        perform(project.compiling ? .compileStop : .compileRun)
    }

    @objc private func togglePDF() { perform(.viewTogglePdf) }

    @objc private func toggleSettings() { app.showProjectSettings.toggle() }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        project.pdfVersion > 0 ? project.pdfURL.map { [$0] } ?? [] : []
    }

    // ---------- Project Settings ----------

    /// Under its toolbar item, or the overflow menu's button while it's there.
    private func showSettings(_ shown: Bool) {
        guard shown else {
            settings?.close()
            return
        }
        guard settings == nil, let item = toolbar.items.first(where: { $0.itemIdentifier == .projectSettings }) else {
            if settings == nil { app.showProjectSettings = false }
            return
        }
        let popover = NSPopover()
        let content = NSHostingController(rootView: ProjectSettingsView(project: project).environment(app))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        settings = popover
        popover.show(relativeTo: item)
    }

    func popoverDidClose(_ notification: Notification) {
        settings = nil
        if app.showProjectSettings { app.showProjectSettings = false }
    }

    // ---------- menus ----------

    private func menuItem(_ title: String, tag: Int = 0, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.representedObject = MenuAction(handler)
        return item
    }

    @objc private func runMenuItem(_ item: NSMenuItem) {
        (item.representedObject as? MenuAction)?.run()
    }

    /// The scale menu's check: the fit in use, or the preset at the scale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.tag {
            case ScaleTag.fitWidth: item.state = pdf.fit == .width ? .on : .off
            case ScaleTag.fitHeight: item.state = pdf.fit == .height ? .on : .off
            case let percent where percent > 0:
                item.state = pdf.fit == nil && Int((pdf.scale * 100).rounded()) == percent ? .on : .off
            default: break
            }
        }
    }
}

/// What a toolbar menu's item does: its menus act on the project they were made for.
private final class MenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
