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
    /// Each navigator's title, symbol, filter text and the filter's tooltip, which follows Xcode's ("Show files with matching name").
    private var spec: (title: String, symbol: String, filter: ReferenceWritableKeyPath<NavigatorModel, String>, filterHelp: String) {
        switch self {
        case .files: (String(localized: "Files"), "folder", \.fileFilter, String(localized: "Show files with matching name"))
        case .outline: (String(localized: "Outline"), "list.bullet.indent", \.outlineFilter, String(localized: "Show sections with matching title"))
        case .search: (String(localized: "Search"), "magnifyingglass", \.searchFilter, String(localized: "Show results with matching text"))
        case .issues: (String(localized: "Issues"), "exclamationmark.triangle", \.issueFilter, String(localized: "Show issues with matching text"))
        }
    }

    var title: String { spec.title }
    var symbol: String { spec.symbol }
    fileprivate var filter: ReferenceWritableKeyPath<NavigatorModel, String> { spec.filter }
    fileprivate var filterHelp: String { spec.filterHelp }

    var shortcut: KeyEquivalent { KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1))) }
}

/// The bar under the navigators: the shown one's filter in a glass capsule, after a + while it's Files.
struct NavigatorFilterBar: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        @Bindable var model = project.navigator
        let shown = model.shown
        // Xcode 27.2's, measured at 2×: 8 pt between its capsules and below and after them, 7 pt before them.
        HStack(spacing: 8) {
            if shown == .files {
                Menu {
                    ForEach([MenuCommand.fileNew, .fileNewFolder, .fileUpload], id: \.self) { command in
                        Button(command.title) { window.perform(command, on: project) }
                    }
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly).frame(width: 28, height: 28).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }
            let kinds = IssueKind.allCases.map { (title: $0.title, isOn: $model.hiddenIssueKinds[lacks: $0]) }
            // The Only errors toggle already shows when warnings are hidden.
            let hiddenKinds = model.hiddenIssueKinds.subtracting(model.showsOnlyErrors ? IssueKind.warnings : [])
            FilterField(text: $model[dynamicMember: shown.filter], help: shown.filterHelp,
                        options: shown == .issues ? kinds : [], hasActiveOptions: shown == .issues && !hiddenKinds.isEmpty) {
                switch shown {
                case .files:
                    FilterToggle(symbol: "clock", label: "Recent files", help: "Show only recent files", isOn: $model.showsOnlyRecentFiles)
                case .issues:
                    FilterToggle(symbol: "exclamationmark.octagon", label: "Only errors", help: "Show only errors", isOn: $model.showsOnlyErrors)
                case .outline, .search: EmptyView()
                }
            }
        }
        .controlSize(.large)
        .padding([.vertical, .trailing], 8)
        .padding(.leading, 7)
    }
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
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .safeAreaBar(edge: .top, spacing: 0) {
            Chooser(project: project).controlSize(.large).padding(.horizontal, 7).padding(.bottom, 8)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { NavigatorFilterBar(project: project) }
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
                                        Image(systemName: "exclamationmark.octagon.fill")
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
            Image(systemName: item.isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
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
