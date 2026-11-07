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

private final class NavigatorChooser: NSSegmentedControl {
    private weak var project: ProjectModel?
    private var watch: Task<Void, Never>?

    isolated deinit { watch?.cancel() }

    init(project: ProjectModel) {
        self.project = project
        super.init(frame: .zero)
        let all = Navigator.allCases
        segmentCount = all.count
        for (index, navigator) in all.enumerated() {
            setImage(NSImage(systemSymbolName: navigator.symbol, accessibilityDescription: navigator.title), forSegment: index)
            setToolTip("\(navigator.title) (⌘\(index + 1))", forSegment: index)
        }
        segmentDistribution = .fillEqually
        trackingMode = .selectOne
        role = .tabs
        controlSize = .large
        setAccessibilityLabel(String(localized: "Navigators"))
        target = self
        action = #selector(choose)
        watch = track({ project.navigator.shown }) { [weak self] in self?.selectedSegment = all.firstIndex(of: $0)! }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func choose() { project?.showNavigator(Navigator.allCases[selectedSegment]) }
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
    // Xcode 27.2's toggles and their words, read from its accessibility: the Project navigator's "Recent files", "Show only
    // recent files", and the Issue navigator's "Only errors", "Show only errors". Xcode's latest issues are those of open
    // documents and the last build, which here are every issue, so this one keeps to the files that were recently open.
    private let recentOnly = FilterToggle("clock", label: String(localized: "Recent files"), help: String(localized: "Show only recent files"))
    private let recentIssues = FilterToggle("clock", label: String(localized: "Issues in recent files"),
                                            help: String(localized: "Show only issues in recent files"))
    private let onlyErrors = FilterToggle("exclamationmark.octagon", label: String(localized: "Only errors"), help: String(localized: "Show only errors"))
    private let filterSymbol = NSImage(systemSymbolName: SearchField.filterSymbol, accessibilityDescription: nil)
    private lazy var menuSymbol = filterSymbol.map { MenuSymbol($0) }
    private let windowModel: WindowModel
    private let project: ProjectModel
    private var watch: Task<Void, Never>?

    isolated deinit { watch?.cancel() }

    init(project: ProjectModel, window: WindowModel) {
        (self.project, windowModel) = (project, window)
        super.init(frame: .zero)
        field.controlSize = .large
        field.drawsBackground = false
        field.placeholderString = String(localized: "Filter")
        field.setAccessibilityLabel(String(localized: "Filter"))
        if let cell = field.cell as? NavigatorField.Cell { (cell.filterBar, cell.menuSymbol) = (true, menuSymbol) }
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filter)

        for (toggle, action) in [(recentOnly, #selector(toggleRecent)), (recentIssues, #selector(toggleRecentIssues)),
                                 (onlyErrors, #selector(toggleErrors))] {
            (toggle.target, toggle.action) = (self, action)
        }
        let content = NSView()
        content.addSubview(field)
        content.addSubview(recentOnly)
        content.addSubview(recentIssues)
        content.addSubview(onlyErrors)
        fieldGlass.contentView = content

        // A glass button, whose symbol takes the label's colour and dims with its window, as stock glass does.
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add"))
        (add.bezelStyle, add.borderShape, add.controlSize) = (.glass, .circle, .large)
        (add.target, add.action) = (self, #selector(showAdd(_:)))
        add.setAccessibilityLabel(String(localized: "Add"))
        addSubview(add)

        fieldGlass.cornerRadius = Self.height / 2 - 1
        fieldGlass.effectIsInteractive = true
        addSubview(fieldGlass)
        watch = track({ Shown(project.navigator) }) { [weak self] in self?.show($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private nonisolated struct Shown: Equatable, Sendable {
        let navigator: Navigator, text: String, recentOnly: Bool, recentIssues: Bool, onlyErrors: Bool, hiddenKinds: Set<IssueKind>

        @MainActor init(_ model: NavigatorModel) {
            (navigator, text) = (model.shown, model[keyPath: model.shown.filter])
            (recentOnly, recentIssues, onlyErrors) = (model.showsOnlyRecentFiles, model.showsOnlyRecentIssues, !model.showsWarnings)
            hiddenKinds = model.hiddenIssueKinds
        }
    }

    private func show(_ shown: Shown) {
        if field.stringValue != shown.text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = shown.text }
        field.toolTip = shown.navigator.filterHelp
        add.isHidden = shown.navigator != .files
        recentOnly.isHidden = shown.navigator != .files
        recentOnly.isOn = shown.recentOnly
        recentIssues.isHidden = shown.navigator != .issues
        recentIssues.isOn = shown.recentIssues
        onlyErrors.isHidden = shown.navigator != .issues
        onlyErrors.isOn = shown.onlyErrors
        showMenu(hiding: shown.navigator == .issues ? shown.hiddenKinds : nil)
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height + 2 * Self.inset) }

    /// Xcode 27.2's navigator filter bar, read from its accessibility frames: a 30 pt field 7 pt from the edges, or 6 pt
    /// after a 30 pt + that sits 6 pt in; toggles 16 pt wide (Only Errors 18) and 4 pt apart, the last ending 7 pt before
    /// the field's end, with the clear button 4 pt before the first.
    override func layout() {
        super.layout()
        let y = (bounds.height - Self.height) / 2
        // Each control's glass is 28 pt inside its 30 pt frame, where Xcode draws a 1 pt ring of the bar's colour.
        let slot = NSRect(x: Self.inset - 1, y: y, width: Self.height, height: Self.height)
        add.frame = slot.insetBy(dx: 1, dy: 1)
        let minX = add.isHidden ? Self.inset : slot.maxX + Self.inset - 1
        fieldGlass.frame = NSRect(x: minX, y: y, width: bounds.width - minX - Self.inset, height: Self.height).insetBy(dx: 1, dy: 1)
        field.frame = fieldGlass.bounds
        let toggles = [recentOnly, recentIssues, onlyErrors].filter { !$0.isHidden }
        var maxX = fieldGlass.bounds.maxX - (Self.inset - 1)
        for toggle in toggles.reversed() {
            // Each symbol centred in its frame and on the capsule's middle, as Xcode's are: their tops 7.5 pt into the capsule
            // at 2x, and at 1x the pixel above, 7 pt (measured).
            let width: CGFloat = toggle === onlyErrors ? 18 : 16
            let y = (fieldGlass.bounds.midY - 8.5).pixelCeiling(window?.backingScaleFactor ?? 2)
            toggle.frame = NSRect(x: maxX - width, y: y, width: width, height: 17)
            maxX = toggle.frame.minX - 4
        }
        // The clear button's rect ends 6 pt before its room, so the room leaves it 4 pt before the first toggle.
        (field.cell as? NavigatorField.Cell)?.room = toggles.isEmpty ? 0 : fieldGlass.bounds.maxX - maxX - 6
        field.needsDisplay = true
    }

    /// The symbols sit on whole pixels, which differ between 1x and 2x screens.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    @objc private func filter() { project.navigator[keyPath: project.navigator.shown.filter] = field.stringValue }

    @objc private func toggleErrors() { project.navigator.showsWarnings = !onlyErrors.isOn }

    @objc private func toggleRecent() { project.navigator.showsOnlyRecentFiles = recentOnly.isOn }

    @objc private func toggleRecentIssues() { project.navigator.showsOnlyRecentIssues = recentIssues.isOn }

    /// The Issues filter has a menu of the kinds of issue it shows, under a chevron after its symbol, as Xcode's Issues filter
    /// has its kinds; the others have neither, their toggles beside the text being all they offer.
    private func showMenu(hiding hidden: Set<IssueKind>?) {
        guard let cell = field.cell as? NSSearchFieldCell else { return }
        if let hidden {
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: String(localized: "Show")))
            for kind in IssueKind.allCases {
                let item = menu.addItem(withTitle: kind.title, action: #selector(toggleKind(_:)), keyEquivalent: "")
                (item.target, item.representedObject, item.state) = (self, kind, hidden.contains(kind) ? .off : .on)
            }
            cell.searchMenuTemplate = menu
        } else {
            cell.searchMenuTemplate = nil
        }
        cell.showSearchImage(hidden == nil ? filterSymbol : menuSymbol?.placeholder)
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
        // Above the +, its foot on the button's top and its edge on the button's, as Xcode 27.2's opens (measured); the
        // menu's size runs 7 pt past the foot of the menu it draws (measured on 27.2). A menu placed beneath ran off the
        // screen's foot and AppKit moved it up over the + and the pointer.
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

/// A toggle beside a filter's text, which shows that it's on as Xcode 27.2's do: its symbol filled and in the accent colour,
/// as a borderless toggle tints its symbol, rather than AppKit's borderless push on/push off, which looks the same either way.
final class FilterToggle: NSButton {
    private let symbol: String
    private var shownSymbol: String?

    init(_ symbol: String, label: String, help: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        isBordered = false
        toolTip = help
        setAccessibilityLabel(label)
        isOn = false
    }

    required init?(coder: NSCoder) { fatalError() }

    var isOn: Bool {
        get { state == .on }
        set {
            if state != (newValue ? .on : .off) { state = newValue ? .on : .off }
            show()
        }
    }

    /// A click flips the state before the action is sent, so the symbol follows it at once.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        show()
        return super.sendAction(action, to: target)
    }

    private func show() {
        let name = state == .on ? "\(symbol).fill" : symbol
        if shownSymbol != name {
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            shownSymbol = name
        }
        contentTintColor = state == .on ? .controlAccentColor : nil
    }
}

/// What a navigator shows when its filter leaves nothing, in Xcode 27.2's words, size and colour (measured).
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
        /// Laid out as Xcode 27.2's navigator filter, measured: the text 1 pt after the symbol's rect, 26 pt into its 30 pt
        /// frame without a menu and 34 with one, and the glass behind the field as its background.
        var filterBar = false
        /// Drawn in the search button's place when the filter has a menu.
        var menuSymbol: MenuSymbol?
        private var hasMenu: Bool { filterBar && searchMenuTemplate != nil }

        /// As wide as AppKit's image, 21 pt with its own menu's chevron, which a narrower rect clips. AppKit draws the image at
        /// the rect's top, rounded down to a pixel, and the 15 pt symbol's glyph a point below that. A filter bar's glyph sits on
        /// the capsule's middle as Xcode's does: its top 7.5 pt into the capsule at 2x, and at 1x the pixel below, 8 pt
        /// (measured), so the rect's top is the next whole pixel down from the middle less 7.5 pt.
        override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
            let scale = controlView?.window?.backingScaleFactor ?? 2
            let image = searchButtonCell?.image?.size ?? NSSize(width: 16, height: 15)
            // Find's small magnifier is centred on its field and 5 pt into it, as Xcode's is (measured).
            let top = filterBar ? rect.midY - 7.5 : rect.midY - image.height / 2
            return NSRect(x: rect.minX + (filterBar ? 6 : 5), y: top.pixelCeiling(scale), width: image.width, height: filterBar ? 15 : image.height)
        }

        override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
            NSRect(x: rect.maxX - room - 6 - 17, y: rect.midY - 8.5, width: 17, height: 17)
        }

        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            let minX = searchButtonRect(forBounds: rect).maxX + 1
            // With a menu Xcode's text top is level with its symbol's, 1 pt above the cell's own centring, which its other
            // filters keep; Find's 11 pt text sits a point lower in its 22 pt field (measured).
            let top = rect.midY - (hasMenu ? 9 : filterBar ? 8 : 7)
            return NSRect(x: minX, y: top, width: cancelButtonRect(forBounds: rect).minX - 6 - minX, height: 20)
        }

        /// A filter bar's field draws no bezel: the bezel's fill over the glass behind it darkened the capsule.
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            if filterBar { drawInterior(withFrame: cellFrame, in: controlView) } else { super.draw(withFrame: cellFrame, in: controlView) }
        }

        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            if hasMenu, let menuSymbol, let button = searchButtonCell {
                // A copy of the button cell draws its image half a point above where the field draws the button's own (measured
                // at 1x and 2x), so it's given the rect half a point lower, which puts the symbol and its chevron where AppKit's
                // own image would be.
                menuSymbol.draw(for: button, in: searchButtonRect(forBounds: cellFrame).offsetBy(dx: 0, dy: 0.5), of: controlView)
            }
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

    /// The filter's help, in the words of Xcode 27.2's navigator filters ("Show files with matching name", "Show results with
    /// matching text"), saying what each of these matches.
    var filterHelp: String {
        switch self {
        case .files: String(localized: "Show files with matching name")
        case .outline: String(localized: "Show sections with matching title")
        case .search: String(localized: "Show results with matching text")
        case .issues: String(localized: "Show issues with matching text")
        }
    }
}

private struct Chooser: NSViewRepresentable {
    let project: ProjectModel

    func makeNSView(context: Context) -> NavigatorChooser { NavigatorChooser(project: project) }
    func updateNSView(_ view: NavigatorChooser, context: Context) {}
}

struct NavigatorPane: View {
    let project: ProjectModel
    let field: FieldHandle

    var body: some View {
        ZStack {
            ForEach(Navigator.allCases, id: \.self) { navigator in
                let shown = navigator == project.navigator.shown
                // disabled() leaves a List in the key-view loop, where focusable(false) takes it out; with no interactions, a
                // shown navigator's focusable(true) adds no stop of its own before its list (27.2).
                list(navigator).opacity(shown ? 1 : 0).disabled(!shown).focusable(shown, interactions: []).accessibilityHidden(!shown)
            }
        }
        .environment(\.sidebarRowSize, .small)
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

    /// The text, the toggles and the kinds are all the filter's, so whichever hides the issues, Xcode's words say so.
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
        let files = items.reduce(into: [String?]()) { files, item in if !files.contains(item.element.file) { files.append(item.element.file) } }
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(files, id: \.self) { file in
                    let rows = items.filter { $0.element.file == file }
                    DisclosureGroup(isExpanded: Binding { !folded.contains(file) } set: { if $0 { folded.remove(file) } else { folded.insert(file) } }) {
                        ForEach(rows, id: \.offset) { IssueRow(item: $0.element, place: $0.offset, project: project, apply: apply) }
                    } label: {
                        Label {
                            Text("\(file?.fileName ?? project.name) \(Text(Self.issues(rows.count)).foregroundStyle(.secondary))")
                                .help(file ?? project.name)
                        } icon: {
                            Image(systemName: file == nil ? "folder.fill" : "text.document")
                                .overlay(alignment: .bottomLeading) {
                                    if rows.contains(where: { $0.element.isError }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.multicolor)
                                            .imageScale(.small)
                                            .offset(x: -3, y: 3)
                                    }
                                }
                        }
                        .lineLimit(1)
                        .navigatorRow()
                        .accessibilityElement(children: .combine)
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
            .alert("\(confirming?.title.text ?? "")?", isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
                   presenting: confirming) { fix in
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
            Image(systemName: item.isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.body)
                .frame(width: 18, height: 18)
        }
        .navigatorRow()
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

extension View {
    func navigatorRow() -> some View { font(.body).padding(.vertical, -2.5) }
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
