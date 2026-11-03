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

/// The navigator's filter, with Files' add menu before it and Issues' errors toggle after it.
struct NavigatorFilter: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        let navigator = project.navigator
        FilterBar(text: Bindable(navigator)[dynamicMember: navigator.shown.filter]) {
            if navigator.shown == .files {
                Menu("Add", systemImage: "plus") {
                    ForEach([MenuCommand.fileNew, .fileNewFolder, .fileUpload], id: \.title) { command in
                        Button(command.title) { window.perform(command, on: project) }
                    }
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        } trailing: {
            if navigator.shown == .issues {
                Toggle("Only Errors", systemImage: "exclamationmark.octagon",
                       isOn: Binding { !navigator.showsWarnings } set: { navigator.showsWarnings = !$0 })
                    .toggleStyle(.button)
                    .help("Show only errors")
            }
        }
        .labelStyle(.iconOnly)
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
}

/// The sidebar: the shown navigator scrolls softly beneath the chooser at its top.
struct NavigatorPane: View {
    let project: ProjectModel
    let field: FieldHandle

    var body: some View {
        // Every navigator stays built, as Xcode's do: building a list on a switch took 45-70 ms on the main thread inside the
        // chooser's click (Instruments, Animation Hitches), so the capsule's glide started late and hitched.
        ZStack {
            ForEach(Navigator.allCases, id: \.self) { navigator in
                let shown = navigator == project.navigator.shown
                // disabled() leaves a List in the key-view loop, where focusable(false) takes it out; with no interactions, a
                // shown navigator's focusable(true) adds no stop of its own before its list (27.2).
                list(navigator).opacity(shown ? 1 : 0).disabled(!shown).focusable(shown, interactions: []).accessibilityHidden(!shown)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top) { chooser }
    }

    private var chooser: some View {
        Picker("Navigators", selection: Bindable(project.navigator).shown) {
            ForEach(Navigator.allCases, id: \.self) { navigator in
                Label(navigator.title, systemImage: navigator.symbol).help("\(navigator.title) (⌘\(String(navigator.shortcut.character)))")
            }
        }
        .pickerStyle(.tabs)
        .buttonSizing(.flexible)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .controlSize(.large)
        // As far in as the sidebar's selection and AppKit's split-item accessories inset theirs, 10 pt (measured on 27.2); the
        // list would otherwise start at its foot.
        .padding([.horizontal, .bottom], 10)
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
        // The list stays when empty, as the other navigators' do, so the chooser keeps to its top over the empty state.
        IssueList(items: items, project: project)
            .overlay { if items.isEmpty { empty } }
    }

    @ViewBuilder private var empty: some View {
        let navigator = project.navigator
        if !navigator.showsWarnings, project.listed.contains(where: { !$0.isError && navigator.matches($0) }) {
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
