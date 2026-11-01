import SwiftUI

/// Find's header: the query field, whose own menu holds Match Case, Whole Words and Replace, the last adding the replacement
/// and Replace All under it.
struct SearchBar: View {
    let project: ProjectModel
    let field: FieldHandle
    @State private var replacing = false

    var body: some View {
        let search = Bindable(project.search)
        if let usages = project.search.usages {
            Text(String(localized: "Usages of \(usages.name)"))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        SearchField(text: search.query, prompt: "Search Project", handle: field,
                    step: { [project] in
                        if !project.search.step($0, in: project.navigator.filtered(project.search.groups ?? [])) { NSSound.beep() }
                    },
                    options: [(String(localized: "Match Case"), search.asked.matchCase), (String(localized: "Whole Words"), search.asked.wholeWords),
                              (String(localized: "Replace"), $replacing)])
        if replacing, project.search.usages == nil {
            SearchField(text: search.replacement, prompt: "With", symbol: "arrow.2.squarepath")
            HStack {
                Spacer()
                // Replace All changes every match in the project, so it waits until the filter no longer hides any.
                Button("Replace All") { Task { await project.replaceAll() } }
                    .disabled(project.search.hitCount == 0 || !project.navigator.searchFilter.isEmpty)
                    .help(project.navigator.searchFilter.isEmpty ? "" : "Clear the filter to replace every match")
            }
        }
    }
}

struct SearchResults: View {
    let project: ProjectModel
    let field: FieldHandle

    var body: some View {
        list
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) { SearchBar(project: project, field: field) }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
            .overlay {
                if let failure = project.search.failure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.search.groups?.isEmpty == true {
                    ContentUnavailableView.search(text: project.search.searched.query)
                }
            }
    }

    private var list: some View {
        List(selection: Bindable(project.search).chosen) { sections { row($0) } }
            .onChange(of: project.search.chosen) { _, id in open(id, focus: false) }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
    }

    private func sections<Row: View>(@ViewBuilder _ hit: @escaping (SearchHit) -> Row) -> some View {
        ForEach(project.navigator.filtered(project.search.groups ?? [])) { group in
            Section {
                ForEach(group.hits) { hit($0) }
            } header: {
                Text("\(Text(group.file.fileName).foregroundStyle(.primary)) \(group.file.parentFolder)")
                    .truncationMode(.middle)
                    .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.file), \(Self.matches(group.hits.count))")
            }
        }
    }

    private func row(_ hit: SearchHit) -> some View {
        Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)")
            .lineLimit(2)
            .navigatorRow()
            .accessibilityValue("Line \(hit.line)")
    }

    private func open(_ id: SearchHit.ID?, focus: Bool) {
        if let found = project.search.groups?.lazy.flatMap(\.hits).first(where: { $0.id == id }) {
            Task { await project.open(found.file, line: found.line, column: found.column, length: found.length, focus: focus, jump: true) }
        }
    }

    static func matches(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) match](inflect: true)").characters)
    }
}

extension View {
    func searching(_ project: ProjectModel) -> some View {
        task(id: project.search.asked) {
            if project.search.isSearching { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await project.search.run(in: project.session)
            guard !Task.isCancelled, project.search.groups != nil, project.search.failure == nil else { return }
            let count = project.search.hitCount
            project.notices.announce(count == 0 ? String(localized: "Not found") : SearchResults.matches(count), queued: true)
        }
    }
}
