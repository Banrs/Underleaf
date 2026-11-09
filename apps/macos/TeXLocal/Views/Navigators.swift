import AppKit
import SwiftUI

final class NavigatorArea: NSViewController {
    private let pane: NSViewController

    init(_ pane: NSViewController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: pane.view.frame)
        addChild(pane)
        view.addSubview(pane.view)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

extension Navigator {
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .outline: String(localized: "Outline")
        case .search: String(localized: "Search")
        case .issues: String(localized: "Issues")
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .outline: "list.bullet.indent"
        case .search: "magnifyingglass"
        case .issues: "exclamationmark.triangle"
        }
    }

    var shortcut: KeyEquivalent { KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1))) }
}

final class NavigatorFilterBar: NSView {
    private let field = NavigatorField()
    private let fieldGlass = NSGlassEffectView()
    private let add = NSButton()
    // Xcode's words. Its recent-issues toggle means issues from open documents and the last build, which here is every
    // issue, so this one keeps to recently opened files.
    private let recentOnly = FilterToggle("clock", label: String(localized: "Recent files"), help: String(localized: "Show only recent files"))
    private let recentIssues = FilterToggle("clock", label: String(localized: "Issues in recent files"),
                                            help: String(localized: "Show only issues in recent files"))
    private let onlyErrors = FilterToggle("exclamationmark.octagon", label: String(localized: "Only errors"), help: String(localized: "Show only errors"))
    private let filterSymbol = NSImage(systemSymbolName: SearchField.filterSymbol, accessibilityDescription: nil)
    private lazy var menuSymbol = filterSymbol?.withMenuChevron()
    private let windowModel: WindowModel
    private let project: ProjectModel

    init(project: ProjectModel, window: WindowModel) {
        (self.project, windowModel) = (project, window)
        super.init(frame: .zero)
        field.controlSize = .large
        field.drawsBackground = false
        field.placeholderString = String(localized: "Filter")
        field.setAccessibilityLabel(String(localized: "Filter"))
        (field.cell as? NavigatorField.Cell)?.filterBar = true
        (field.cell as? NSSearchFieldCell)?.showSearchImage(filterSymbol)
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filter)

        for (toggle, action) in [(recentOnly, #selector(toggleRecent)), (recentIssues, #selector(toggleRecentIssues)),
                                 (onlyErrors, #selector(toggleErrors))] {
            (toggle.target, toggle.action) = (self, action)
        }
        let content = NSView()
        for view in [field, recentOnly, recentIssues, onlyErrors] { content.addSubview(view) }
        fieldGlass.contentView = content

        // Stock glass, so the symbol takes the label colour and dims with the window.
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add"))
        (add.bezelStyle, add.borderShape, add.controlSize) = (.glass, .circle, .large)
        (add.target, add.action) = (self, #selector(showAdd(_:)))
        addSubview(add)

        fieldGlass.cornerRadius = Self.height / 2 - 1
        fieldGlass.effectIsInteractive = true
        addSubview(fieldGlass)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height + 2 * Self.inset) }

    /// Shows the navigator's filter as well as placing the controls, since AppKit lays the bar out again whenever what this
    /// reads of the model changes. Xcode's geometry: a 30 pt field 7 pt from the edges, or 6 pt after a 30 pt + that sits
    /// 6 pt in; toggles 16 pt wide (18 for errors) and 4 pt apart, the last 7 pt from the field's end, with the clear button
    /// 4 pt before the first.
    override func layout() {
        super.layout()
        let model = project.navigator, shown = model.shown, text = model[keyPath: shown.filter]
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        field.toolTip = shown.filterHelp
        add.isHidden = shown != .files
        recentOnly.isHidden = shown != .files
        recentOnly.isOn = model.showsOnlyRecentFiles
        recentIssues.isHidden = shown != .issues
        recentIssues.isOn = model.showsOnlyRecentIssues
        onlyErrors.isHidden = shown != .issues
        onlyErrors.isOn = model.showsOnlyErrors
        showMenu(shown == .issues)

        let y = (bounds.height - Self.height) / 2
        // Xcode leaves a 1 pt ring of the bar's colour around each 28 pt capsule.
        let slot = NSRect(x: Self.inset - 1, y: y, width: Self.height, height: Self.height)
        add.frame = slot.insetBy(dx: 1, dy: 1)
        let minX = add.isHidden ? Self.inset : slot.maxX + Self.inset - 1
        fieldGlass.frame = NSRect(x: minX, y: y, width: bounds.width - minX - Self.inset, height: Self.height).insetBy(dx: 1, dy: 1)
        field.frame = fieldGlass.bounds
        let toggles = [recentOnly, recentIssues, onlyErrors].filter { !$0.isHidden }
        var maxX = fieldGlass.bounds.maxX - (Self.inset - 1)
        for toggle in toggles.reversed() {
            // Centred on the capsule: tops 7.5 pt in at 2x, a pixel higher at 1x.
            let width: CGFloat = toggle === onlyErrors ? 18 : 16
            let y = (fieldGlass.bounds.midY - 8.5).pixelCeiling(window?.backingScaleFactor ?? 2)
            toggle.frame = NSRect(x: maxX - width, y: y, width: width, height: 17)
            maxX = toggle.frame.minX - 4
        }
        // The clear button ends 6 pt before the room, which leaves it 4 pt before the first toggle.
        (field.cell as? NavigatorField.Cell)?.room = toggles.isEmpty ? 0 : fieldGlass.bounds.maxX - maxX - 6
        field.needsDisplay = true
    }

    /// The symbols sit on whole pixels, which differ between 1x and 2x screens.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    @objc private func filter() { project.navigator[keyPath: project.navigator.shown.filter] = field.stringValue }

    @objc private func toggleErrors() { project.navigator.showsOnlyErrors = onlyErrors.isOn }

    @objc private func toggleRecent() { project.navigator.showsOnlyRecentFiles = recentOnly.isOn }

    @objc private func toggleRecentIssues() { project.navigator.showsOnlyRecentIssues = recentIssues.isOn }

    /// Only the Issues filter has a menu, listing the kinds of issue it shows; each is ticked as the menu opens.
    private func showMenu(_ shown: Bool) {
        guard let cell = field.cell as? NSSearchFieldCell, (cell.searchMenuTemplate != nil) != shown else { return }
        if shown {
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: String(localized: "Show")))
            for kind in IssueKind.allCases {
                let item = menu.addItem(withTitle: kind.title, action: #selector(toggleKind(_:)), keyEquivalent: "")
                (item.target, item.representedObject) = (self, kind)
            }
            cell.searchMenuTemplate = menu
        } else {
            cell.searchMenuTemplate = nil
        }
        cell.showSearchImage(shown ? menuSymbol : filterSymbol)
    }

    @objc private func toggleKind(_ item: NSMenuItem) {
        guard let kind = item.representedObject as? IssueKind else { return }
        if project.navigator.hiddenIssueKinds.remove(kind) == nil { project.navigator.hiddenIssueKinds.insert(kind) }
    }

    @objc private func showAdd(_ button: NSButton) {
        let menu = NSMenu()
        for command in [MenuCommand.fileNew, .fileNewFolder, .fileUpload] {
            let item = menu.addItem(withTitle: command.title, action: #selector(add(_:)), keyEquivalent: "")
            (item.target, item.representedObject) = (self, command)
        }
        // Above the +, edges aligned, as Xcode opens it; `menu.size` is 7 pt taller than the menu drawn. Opened below, the
        // menu could run off the screen, and AppKit would then move it over the + and the pointer.
        guard let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY + menu.size.height - 7), in: nil)
    }

    @objc private func add(_ item: NSMenuItem) {
        if let command = item.representedObject as? MenuCommand { windowModel.perform(command, on: project) }
    }

    private static let height: CGFloat = 30
    private static let inset: CGFloat = 7
}

extension NavigatorFilterBar: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let kind = item.representedObject as? IssueKind { item.state = project.navigator.hiddenIssueKinds.contains(kind) ? .off : .on }
        return true
    }
}

/// A toggle beside a filter's text, filled and in the accent colour while on, as in Xcode.
final class FilterToggle: NSButton {
    init(_ symbol: String, label: String, help: String) {
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        isBordered = false
        // Shows the alternate image when on; by default a borderless one looks the same on and off.
        (cell as? NSButtonCell)?.showsStateBy = .contentsCellMask
        // VoiceOver reads the shown image's description: a label set on the button never reaches its cell.
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        alternateImage = NSImage(systemSymbolName: symbol + ".fill", accessibilityDescription: label)
        toolTip = help
    }

    required init?(coder: NSCoder) { fatalError() }

    var isOn: Bool {
        get { state == .on }
        set {
            state = newValue ? .on : .off
            tint()
        }
    }

    /// A click changes the state without the setter, so the tint follows here.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        tint()
        return super.sendAction(action, to: target)
    }

    private func tint() { contentTintColor = isOn ? .controlAccentColor : nil }
}

/// What a navigator shows when its filter leaves nothing: Xcode's words, size and colour.
struct NoFilterResults: View {
    var body: some View {
        Text("No Filter Results")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class NavigatorField: NSSearchField {
    final class Cell: NSSearchFieldCell {
        var room: CGFloat = 0
        /// Laid out like Xcode's navigator filter: the text 1 pt after the symbol's rect, 26 pt into the 30 pt frame (34 with a
        /// menu), and the glass behind the field as its background.
        var filterBar = false
        private var hasMenu: Bool { filterBar && searchMenuTemplate != nil }

        /// As wide as AppKit's image (21 pt with its menu chevron; a narrower rect clips it). AppKit draws the image at the
        /// rect's top, rounded down to a pixel, and the 15 pt symbol's ink starts a point lower. A filter bar centres the ink on
        /// the capsule as Xcode does, so the rect's top is the middle less 7.5 pt, rounded down a pixel.
        override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
            let scale = controlView?.window?.backingScaleFactor ?? 2
            let image = searchButtonCell?.image?.size ?? NSSize(width: 16, height: 15)
            // Find's small magnifier is centred and 5 pt in, as in Xcode.
            let top = filterBar ? rect.midY - 7.5 : rect.midY - image.height / 2
            return NSRect(x: rect.minX + (filterBar ? 6 : 5), y: top.pixelCeiling(scale), width: image.width, height: filterBar ? 15 : image.height)
        }

        override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
            NSRect(x: rect.maxX - room - 6 - 17, y: rect.midY - 8.5, width: 17, height: 17)
        }

        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            let minX = searchButtonRect(forBounds: rect).maxX + 1
            // With a menu, Xcode's text top is level with the symbol's, 1 pt above the cell's centring; Find's 11 pt text sits
            // 1 pt lower in its 22 pt field.
            let top = rect.midY - (hasMenu ? 9 : filterBar ? 8 : 7)
            return NSRect(x: minX, y: top, width: cancelButtonRect(forBounds: rect).minX - 6 - minX, height: 20)
        }

        /// A filter bar's field draws no bezel: its fill over the glass darkened the capsule.
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            if filterBar { drawInterior(withFrame: cellFrame, in: controlView) } else { super.draw(withFrame: cellFrame, in: controlView) }
        }
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    func keepRecents(as name: String) {
        recentsAutosaveName = name
        let menu = NSMenu()
        for (title, tag) in [(String(localized: "Recent Searches"), NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag),
                             (String(localized: "Clear Recents"), NSSearchField.clearRecentsMenuItemTag),
                             (String(localized: "No Recent Searches"), NSSearchField.noRecentsMenuItemTag)] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").tag = tag
        }
        searchMenuTemplate = menu
    }

    /// Adds the field's text to its recents, which a field sending each keystroke never does itself.
    func remember() {
        guard !stringValue.isEmpty else { return }
        recentSearches = Array(([stringValue] + recentSearches.filter { $0 != stringValue }).prefix(10))
    }
}

private extension Navigator {
    var filter: ReferenceWritableKeyPath<NavigatorModel, String> {
        switch self {
        case .files: \.fileFilter
        case .outline: \.outlineFilter
        case .search: \.searchFilter
        case .issues: \.issueFilter
        }
    }

    /// The filter's tooltip, following Xcode's ("Show files with matching name").
    var filterHelp: String {
        switch self {
        case .files: String(localized: "Show files with matching name")
        case .outline: String(localized: "Show sections with matching title")
        case .search: String(localized: "Show results with matching text")
        case .issues: String(localized: "Show issues with matching text")
        }
    }
}

/// The tabs picker, its segments sharing the sidebar's width as Xcode's choosers do however few their choices.
private struct Chooser: View {
    let project: ProjectModel

    var body: some View {
        Picker("Navigators", selection: Binding { project.navigator.shown } set: { project.showNavigator($0) }) {
            ForEach(Navigator.allCases, id: \.self) { navigator in
                // VoiceOver reads a segment by its image's description, which for a symbol Image is the symbol's own ("warning").
                Image(nsImage: NSImage(systemSymbolName: navigator.symbol, accessibilityDescription: navigator.title)!)
                    .help("\(navigator.title) (⌘\(String(navigator.shortcut.character)))")
            }
        }
        .pickerStyle(.tabs)
        .buttonSizing(.flexible)
        .labelsHidden()
    }
}

struct NavigatorPane: View {
    let project: ProjectModel
    let field: FieldHandle

    var body: some View {
        ZStack {
            ForEach(Navigator.allCases, id: \.self) { navigator in
                let shown = navigator == project.navigator.shown
                // disabled() leaves a List in the key-view loop and focusable(false) takes it out; with no interactions,
                // focusable(true) adds no stop of its own before the list.
                list(navigator).opacity(shown ? 1 : 0).disabled(!shown).focusable(shown, interactions: []).accessibilityHidden(!shown)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            Chooser(project: project).controlSize(.large).padding(.horizontal, 7).padding(.bottom, project.navigator.shown == .search ? 2 : 8)
        }
    }

    @ViewBuilder private func list(_ navigator: Navigator) -> some View {
        switch navigator {
        case .files: FilesList(project: project)
        case .outline: OutlineList(project: project)
        case .search: SearchResults(project: project, field: field)
        case .issues: IssueNavigator(project: project)
        }
    }
}

private struct IssueNavigator: View {
    let project: ProjectModel

    var body: some View {
        let items = project.navigator.rows(of: project.listed)
        IssueList(items: items, project: project)
            .overlay { if items.isEmpty { empty } }
    }

    /// Whatever hides the issues is part of the filter, so Xcode's "No Filter Results" covers every case.
    @ViewBuilder private var empty: some View {
        if project.listed.isEmpty {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        } else {
            NoFilterResults()
        }
    }
}

private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel
    @State private var folded: Set<String?> = []
    @State private var confirming: Fix?

    var body: some View {
        let selection = Binding { project.chosenIssue } set: { project.chooseIssue($0, focus: false) }
        let byFile = Dictionary(grouping: items, by: \.element.file)
        var seen = Set<String?>()
        let files = items.map(\.element.file).filter { seen.insert($0).inserted }
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(files, id: \.self) { file in
                    let rows = byFile[file] ?? []
                    let name = file?.fileName ?? project.name
                    let errors = rows.contains { $0.element.isError }
                    DisclosureGroup(isExpanded: $folded[lacks: file]) {
                        ForEach(rows, id: \.offset) { IssueRow(item: $0.element, place: $0.offset, project: project, apply: apply) }
                    } label: {
                        Label {
                            Text("\(name) \(Text(Self.issues(rows.count)).foregroundStyle(.secondary))")
                        } icon: {
                            Image(systemName: file.map { project.tree.node(at: $0)?.symbol ?? "text.document" } ?? "folder.fill")
                                .overlay(alignment: .bottomLeading) {
                                    if errors {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.multicolor)
                                            .imageScale(.small)
                                            .offset(x: -3, y: 3)
                                    }
                                }
                        }
                        .lineLimit(1)
                        // VoiceOver reads the name and count shown and what the red badge means, then the path as its hint.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(errors ? "\(name), \(Self.issues(rows.count)), including errors" : "\(name), \(Self.issues(rows.count))")
                        .help(file ?? project.name)
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Issues")
            .contextMenu(forSelectionType: Int.self) { rows in
                if let item = rows.first.flatMap(item) {
                    if item.file != nil { Button(item.line == nil ? "Open File" : "Go to Line") { open(item) } }
                    if let fix = item.fix { Button(fix.title.text) { apply(fix) }.disabled(project.fixing != nil) }
                    Button("Copy") { NSPasteboard.general.replaceContents(with: item.message.text) }
                }
            } primaryAction: { rows in if let item = rows.first.flatMap(item) { open(item) } }
            .copyable(project.chosenIssue.flatMap(item).map { [$0.message.text] } ?? [])
            .alert("\(confirming?.title.text ?? "")?", item: $confirming) { fix in
                Button(fix.title.text) { Task { await project.run(fix) } }
                Button("Cancel", role: .cancel) {}
            } message: { fix in
                Text(fix.confirm?.text ?? "")
            }
            .onChange(of: project.chosenIssue) { _, place in if let place { proxy.scrollTo(place) } }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _ in
                if let place = project.chosenIssue { proxy.scrollTo(place) }
            }
        }
    }

    private static func issues(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) issue](inflect: true)").characters)
    }

    private func item(_ id: Int) -> LogItem? { items.first { $0.offset == id }?.element }

    private func open(_ item: LogItem) { if let file = item.file { Task { await project.open(file, line: item.line, jump: true) } } }

    private func apply(_ fix: Fix) { if fix.confirm == nil { Task { await project.run(fix) } } else { confirming = fix } }
}

private struct IssueRow: View {
    let item: LogItem
    let place: Int
    let project: ProjectModel
    let apply: (Fix) -> Void

    var body: some View {
        VStack(alignment: .trailing) {
            label
            if let fix = item.fix, place == project.chosenIssue || project.fixing == fix { offer(fix) }
        }
    }

    private var label: some View {
        Label {
            Text(item.message.text).lineLimit(place == project.chosenIssue ? nil : 3)
        } icon: {
            Image(systemName: item.isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        .help([item.message.text, item.explain?.text].compactMap(\.self).joined(separator: "\n\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message.text)")
        .accessibilityValue([item.explain?.text, location].compactMap(\.self).joined(separator: " "))
    }

    @ViewBuilder private func offer(_ fix: Fix) -> some View {
        if project.fixing == fix {
            ProgressView().controlSize(.small).accessibilityLabel(fix.title.text)
        } else {
            Button(fix.title.text) { apply(fix) }
                .controlSize(.small)
                .disabled(project.fixing != nil)
                .help(fix.help.text)
        }
    }

    private var location: String? { item.file.map { file in item.line.map { "\(file), line \($0)" } ?? file } }
}

func filtered<Node>(_ nodes: [Node], _ children: WritableKeyPath<Node, [Node]?>, by text: String, name: (Node) -> String) -> [Node] {
    text.isEmpty ? nodes : filtered(nodes, children) { name($0).localizedCaseInsensitiveContains(text) }
}

/// The nodes kept, whole, and the folders that lead to them.
func filtered<Node>(_ nodes: [Node], _ children: WritableKeyPath<Node, [Node]?>, keeping keep: (Node) -> Bool) -> [Node] {
    nodes.compactMap { node in
        if keep(node) { return node }
        var node = node
        guard let kids = node[keyPath: children].map({ filtered($0, children, keeping: keep) }), !kids.isEmpty else { return nil }
        node[keyPath: children] = kids
        return node
    }
}
