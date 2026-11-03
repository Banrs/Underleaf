import AppKit
import SwiftUI

/// Find's header: what to find and how, the query and, in Replace, the replacement and its buttons, then the count of results.
private struct FindHeader: View {
    let project: ProjectModel
    let field: FieldHandle
    let groups: [SearchGroup]

    var body: some View {
        @Bindable var search = project.search
        VStack {
            HStack {
                if let usages = search.usages {
                    Text("Usages of \(usages.name)").bold().lineLimit(1).truncationMode(.middle)
                } else {
                    Picker("Mode", selection: $search.replacing) {
                        Text("Find").tag(false)
                        Text("Replace").tag(true)
                    }
                    Picker("Match", selection: $search.asked.wholeWords) {
                        Text("Containing").tag(false)
                        Text("Matching Word").tag(true)
                    }
                    Spacer()
                    Toggle("Match Case", systemImage: "textformat", isOn: $search.asked.matchCase).help("Match Case")
                }
            }
            .pickerStyle(.menu)
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .controlSize(.small)
            SearchField(text: $search.query, prompt: String(localized: "Search Project"), handle: field, step: { step in
                if !search.step(step, in: project.navigator.filtered(search.groups ?? [])) { NSSound.beep() }
            }, recents: "Find Queries")
            if search.replacing, search.usages == nil {
                SearchField(text: $search.replacement, prompt: String(localized: "Replace With"), recents: "Replacements")
                HStack {
                    Spacer()
                    // Neither is the default button, since Replace All can't be undone file by file.
                    Button("Replace") { Task { await project.replaceChosen() } }
                        .disabled(search.chosen == nil)
                        .help("Replace the selected search result")
                    // Replace All changes every match in the project, so it waits until the filter no longer hides any.
                    let filtered = !project.navigator.searchFilter.isEmpty
                    Button("Replace All") { Task { await project.replaceAll() } }
                        .disabled(search.hitCount == 0 || filtered)
                        .help(filtered ? String(localized: "Clear the filter to replace every match") : String(localized: "Replace all search results"))
                }
            }
            let hits = groups.reduce(0) { $0 + $1.hits.count }
            if hits > 0 {
                Text("^[\(hits) result](inflect: true) in ^[\(groups.count) file](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom], 10)
    }
}

/// Find's results as Xcode lists them: under a count, each file a row that folds, its results under it.
struct SearchResults: View {
    let project: ProjectModel
    let field: FieldHandle
    @State private var folded: Set<String> = []

    var body: some View {
        let groups = project.navigator.filtered(project.search.groups ?? [])
        list(groups)
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            .safeAreaBar(edge: .top) { FindHeader(project: project, field: field, groups: groups) }
            .overlay {
                if let failure = project.search.failure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.search.groups?.isEmpty == true {
                    ContentUnavailableView.search(text: project.search.searched.query)
                }
            }
            .onChange(of: project.search.searched) { folded = [] }
            .task(id: project.search.asked) {
                if project.search.isSearching { try? await Task.sleep(for: .milliseconds(200)) }
                guard !Task.isCancelled else { return }
                guard await project.search.run({ try await project.session.call($0) }) else { return }
                guard !Task.isCancelled, project.search.groups != nil, project.search.failure == nil else { return }
                let count = project.search.hitCount
                project.notices.announce(count == 0 ? String(localized: "Not found") : Self.matches(count), queued: true)
            }
    }

    private func list(_ groups: [SearchGroup]) -> some View {
        ScrollViewReader { proxy in
            List(selection: Bindable(project.search).chosen) {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: Binding { !folded.contains(group.file) } set: {
                        if $0 { folded.remove(group.file) } else { folded.insert(group.file) }
                    }) {
                        ForEach(group.hits) { row($0) }
                    } label: {
                        file(group).selectionDisabled()
                    }
                }
            }
            .onChange(of: project.search.chosen) { _, id in
                if let hit = hit(id) {
                    folded.remove(hit.file)
                    proxy.scrollTo(hit.id)
                }
                open(id, focus: false)
            }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
        }
    }

    /// Xcode's file rows: the file's icon, its name a little heavier than the results, then its folder, dimmer.
    private func file(_ group: SearchGroup) -> some View {
        Label {
            Text("\(Text(group.file.fileName).fontWeight(.medium)) \(Text(group.file.parentFolder.replacing("/", with: " ▸ ")).foregroundStyle(.secondary))")
                .lineLimit(1)
        } icon: {
            Image(systemName: project.tree.node(at: group.file)?.symbol ?? "text.document")
        }
        .navigatorRow()
        .help(group.file)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.file), \(Self.matches(group.hits.count))")
    }

    /// Xcode's result rows: a line glyph, then the line, its match bold.
    private func row(_ hit: SearchHit) -> some View {
        Label {
            Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)").lineLimit(3)
        } icon: {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .navigatorRow()
        .accessibilityValue("Line \(hit.line)")
    }

    private func hit(_ id: SearchHit.ID?) -> SearchHit? { project.search.groups?.lazy.flatMap(\.hits).first { $0.id == id } }

    private func open(_ id: SearchHit.ID?, focus: Bool) {
        if let found = hit(id) {
            Task { await project.open(found.file, line: found.line, column: found.column, length: found.length, focus: focus, jump: true) }
        }
    }

    static func matches(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) match](inflect: true)").characters)
    }
}
