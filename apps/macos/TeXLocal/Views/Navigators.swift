import AppKit
import SwiftUI

/// The navigator chooser across the sidebar's top, as Xcode's: a tabs-role segmented control at the large size,
/// its segments filling the width and starting 8 pt in from the sidebar's edges, where Xcode's start.
final class NavigatorBar: NSView {
    private let control = NSSegmentedControl()
    private weak var project: ProjectModel?
    private var watch: Task<Void, Never>?

    init(project: ProjectModel) {
        self.project = project
        super.init(frame: .zero)
        let all = Navigator.allCases
        control.segmentCount = all.count
        for (index, navigator) in all.enumerated() {
            control.setImage(NSImage(systemSymbolName: navigator.symbol, accessibilityDescription: navigator.title), forSegment: index)
            control.setToolTip("\(navigator.title) (⌘\(index + 1))", forSegment: index)
        }
        control.trackingMode = .selectOne
        control.role = .tabs
        control.controlSize = .large
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(String(localized: "Navigators"))
        control.target = self
        control.action = #selector(choose)
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        watch = track({ project.navigator.shown }) { [weak self] in self?.control.selectedSegment = all.firstIndex(of: $0)! }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func choose() { project?.showNavigator(Navigator.allCases[control.selectedSegment]) }
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

/// The filter at the navigator's foot, as Xcode's: a large field 7 pt in from the sidebar's edges, its toggles inside
/// its trailing end, beside an add menu in Files.
struct NavigatorFilter: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        @Bindable var navigator = project.navigator
        HStack(spacing: 6) {
            switch navigator.shown {
            case .files:
                Menu {
                    ForEach([MenuCommand.fileNew, .fileNewFolder, .fileUpload], id: \.self) { command in
                        Button(command.title) { window.perform(command, on: project) }
                    }
                } label: {
                    Image(systemName: "plus").accessibilityLabel("Add")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .fixedSize()
                SearchField.filter($navigator.fileFilter)
            case .outline: SearchField.filter($navigator.outlineFilter)
            case .search: SearchField.filter($navigator.searchFilter)
            case .issues:
                SearchField(text: $navigator.issueFilter, prompt: String(localized: "Filter"), symbol: SearchField.filterSymbol,
                            trailingRoom: Self.toggle)
                .overlay(alignment: .trailing) {
                    Toggle(isOn: Binding { !navigator.showsWarnings } set: { navigator.showsWarnings = !$0 }) {
                        Label("Only Errors", systemImage: "exclamationmark.octagon")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .help("Show only errors")
                    .padding(.trailing, 7)
                }
            }
        }
        .controlSize(.large)
        .padding(7)
    }

    private static let toggle: CGFloat = 24
}

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
