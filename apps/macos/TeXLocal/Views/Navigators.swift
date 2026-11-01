import AppKit
import SwiftUI

/// The sidebar's content from the toolbar's foot, so its lists scroll beneath the chooser but not on into the titlebar, as
/// Xcode's stop.
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

/// The navigator chooser: a tabs-role segmented control at the large size, its segments sharing the sidebar's width, as
/// Xcode's choosers do however few their choices.
private final class NavigatorChooser: NSSegmentedControl {
    private weak var project: ProjectModel?
    private var watch: Task<Void, Never>?

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

/// The filter bar at the navigator's foot, built as Xcode's large one is: interactive Liquid Glass, which swells under a press,
/// around a large search field 28 pt tall and 8 pt from the bar's edges, and in Files around a 28 pt add menu 7 pt in, 8 pt
/// before the field; in Issues a toggle inside the field's trailing end shows only errors.
final class NavigatorFilterBar: NSView {
    private let field = RoomySearchField()
    private let fieldGlass = NSGlassEffectView()
    private let addGlass = NSGlassEffectView()
    private let onlyErrors = NSButton()
    private let windowModel: WindowModel
    private let project: ProjectModel
    private var watch: Task<Void, Never>?

    init(project: ProjectModel, window: WindowModel) {
        (self.project, windowModel) = (project, window)
        super.init(frame: .zero)
        field.controlSize = .large
        field.drawsBackground = false
        field.placeholderString = String(localized: "Filter")
        field.setAccessibilityLabel(String(localized: "Filter"))
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.image = NSImage(systemSymbolName: SearchField.filterSymbol, accessibilityDescription: nil)
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filter)

        onlyErrors.setButtonType(.pushOnPushOff)
        onlyErrors.isBordered = false
        onlyErrors.image = NSImage(systemSymbolName: "exclamationmark.octagon", accessibilityDescription: String(localized: "Only Errors"))
        onlyErrors.alternateImage = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: String(localized: "Only Errors"))
        onlyErrors.toolTip = String(localized: "Show only errors")
        onlyErrors.setAccessibilityLabel(String(localized: "Only Errors"))
        onlyErrors.target = self
        onlyErrors.action = #selector(toggleErrors)
        let content = NSView()
        content.addSubview(field)
        content.addSubview(onlyErrors)
        fieldGlass.contentView = content

        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.isBordered = false
        (add.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        add.addItem(withTitle: "")
        add.lastItem?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add"))
        for command in [MenuCommand.fileNew, .fileNewFolder, .fileUpload] {
            add.menu?.addItem(withTitle: command.title, action: #selector(add(_:)), keyEquivalent: "").representedObject = command
        }
        add.itemArray.dropFirst().forEach { $0.target = self }
        add.setAccessibilityLabel(String(localized: "Add"))
        addGlass.contentView = add

        for glass in [addGlass, fieldGlass] {
            glass.cornerRadius = Self.height / 2
            glass.effectIsInteractive = true
            addSubview(glass)
        }
        watch = track({ Shown(project.navigator) }) { [weak self] in self?.show($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private nonisolated struct Shown: Equatable, Sendable {
        let navigator: Navigator, text: String, onlyErrors: Bool

        @MainActor init(_ model: NavigatorModel) {
            (navigator, text, onlyErrors) = (model.shown, model[keyPath: model.shown.filter], !model.showsWarnings)
        }
    }

    private func show(_ shown: Shown) {
        if field.stringValue != shown.text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = shown.text }
        addGlass.isHidden = shown.navigator != .files
        onlyErrors.isHidden = shown.navigator != .issues
        onlyErrors.state = shown.onlyErrors ? .on : .off
        (field.cell as? RoomySearchField.Cell)?.room = onlyErrors.isHidden ? 0 : Self.toggle
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height + 2 * 8) }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.height) / 2
        addGlass.frame = NSRect(x: 7, y: y, width: Self.height, height: Self.height)
        let minX = addGlass.isHidden ? 8 : addGlass.frame.maxX + 8
        fieldGlass.frame = NSRect(x: minX, y: y, width: bounds.width - minX - 8, height: Self.height)
        field.frame = fieldGlass.bounds
        onlyErrors.frame = NSRect(x: fieldGlass.bounds.maxX - Self.toggle - 4, y: 0, width: Self.toggle, height: Self.height)
    }

    @objc private func filter() { project.navigator[keyPath: project.navigator.shown.filter] = field.stringValue }

    @objc private func toggleErrors() { project.navigator.showsWarnings = onlyErrors.state == .off }

    @objc private func add(_ item: NSMenuItem) {
        if let command = item.representedObject as? MenuCommand { windowModel.perform(command, on: project) }
    }

    /// Xcode's large filter field and add menu, and the macOS UI Kit's large search field: 28 pt tall.
    private static let height: CGFloat = 28
    private static let toggle: CGFloat = 24
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
}

private struct Chooser: NSViewRepresentable {
    let project: ProjectModel

    func makeNSView(context: Context) -> NavigatorChooser { NavigatorChooser(project: project) }
    func updateNSView(_ view: NavigatorChooser, context: Context) {}
}

/// The sidebar as Xcode's navigator area: the shown navigator scrolls beneath the chooser at its top, softly, its rows
/// starting 8 pt below it, as Xcode's do.
struct NavigatorPane: View {
    let project: ProjectModel
    let field: FieldHandle

    var body: some View {
        Group {
            switch project.navigator.shown {
            case .files: FilesList(project: project)
            case .outline: OutlineList(project: project)
            case .search: SearchResults(project: project, field: field)
            case .issues: IssueNavigator(project: project)
            }
        }
        .searching(project)
        .environment(\.sidebarRowSize, .small)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) { Chooser(project: project).controlSize(.large).padding(.horizontal, 7).padding(.bottom, 8) }
    }
}

private struct IssueNavigator: View {
    let project: ProjectModel

    var body: some View {
        let navigator = project.navigator
        let items = navigator.rows(of: project.listed)
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !navigator.showsWarnings, project.listed.contains(where: { !$0.isError && navigator.matches($0) }) {
            ContentUnavailableView {
                Label("Warnings Hidden", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Show Warnings") { navigator.showsWarnings = true }
            }
        } else if !navigator.issueFilter.isEmpty {
            ContentUnavailableView.search(text: navigator.issueFilter)
        } else {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        }
    }
}

private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel
    @State private var folded: Set<String?> = []

    var body: some View {
        let selection = Binding { project.chosenIssue } set: { project.chooseIssue($0, focus: false) }
        let files = items.reduce(into: [String?]()) { files, item in if !files.contains(item.element.file) { files.append(item.element.file) } }
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(files, id: \.self) { file in
                    let rows = items.filter { $0.element.file == file }
                    DisclosureGroup(isExpanded: Binding { !folded.contains(file) } set: { if $0 { folded.remove(file) } else { folded.insert(file) } }) {
                        ForEach(rows, id: \.offset) { IssueRow(item: $0.element, place: $0.offset, project: project) }
                    } label: {
                        Label {
                            Text("\(file?.fileName ?? project.name) \(Text(Self.issues(rows.count)).foregroundStyle(.secondary))")
                                .help(file ?? project.name)
                        } icon: {
                            Image(systemName: file == nil ? "folder" : "text.document")
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
                    Button("Copy") { NSPasteboard.general.replaceContents(with: item.message.text) }
                }
            } primaryAction: { rows in if let item = rows.first.flatMap(item) { open(item) } }
            .copyable(project.chosenIssue.flatMap(item).map { [$0.message.text] } ?? [])
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
}

private struct IssueRow: View {
    let item: LogItem
    let place: Int
    let project: ProjectModel
    @State private var confirming = false

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
            Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
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
            Button(fix.title.text) { if fix.confirm == nil { run(fix) } else { confirming = true } }
                .controlSize(.small)
                .disabled(project.fixing != nil)
                .help(fix.help.text)
                .alert("\(fix.title.text)?", isPresented: $confirming) {
                    Button(fix.title.text) { run(fix) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(fix.confirm?.text ?? "")
                }
        }
    }

    private func run(_ fix: Fix) { Task { await project.run(fix) } }

    private var location: String? { item.file.map { file in item.line.map { "\(file), line \($0)" } ?? file } }
}

extension View {
    /// Xcode's navigator rows: body text, about 16 pt more for each further line. A small sidebar row pads its content by
    /// 11 pt where Xcode's pad by 6, and List on the Mac takes no row insets, so the content gives back 5 pt; the small
    /// size's 24 pt floor stays, against Xcode's 22.
    func navigatorRow() -> some View { font(.body).padding(.vertical, -2.5) }
}

func filtered<Node>(_ nodes: [Node], _ children: WritableKeyPath<Node, [Node]?>, by text: String, name: (Node) -> String) -> [Node] {
    guard !text.isEmpty else { return nodes }
    return nodes.compactMap { node in
        if name(node).localizedCaseInsensitiveContains(text) { return node }
        var node = node
        guard let kids = node[keyPath: children].map({ filtered($0, children, by: text, name: name) }), !kids.isEmpty else { return nil }
        node[keyPath: children] = kids
        return node
    }
}
