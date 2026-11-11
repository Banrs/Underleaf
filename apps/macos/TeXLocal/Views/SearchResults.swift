import AppKit
import SwiftUI

/// The search's field and options, laid out as the system's find bar is: the options in the field's menu and Replace
/// beside it, with the replacement and its buttons below while it's on.
private struct FindHeader: View {
    let project: ProjectModel
    let field: FieldHandle
    let groups: [SearchGroup]

    var body: some View {
        @Bindable var search = project.search
        let hits = groups.reduce(0) { $0 + $1.hits.count }
        VStack(spacing: 6) {
            if let usages = search.usages {
                Text("Usages of \(usages.name)").font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                SearchField(text: $search.query, prompt: String(localized: "Search Project"), handle: field, recents: "Find Queries",
                            step: { if !project.search.step($0, in: groups) { NSSound.beep() } },
                            options: search.usages == nil ? [(String(localized: "Match Case"), $search.asked.matchCase),
                                                             (String(localized: "Whole Words"), $search.asked.wholeWords)] : [])
                if search.usages == nil { Toggle("Replace", isOn: $search.replacing).controlSize(.regular) }
            }
            if search.showsReplace {
                SearchField(text: $search.replacement, prompt: String(localized: "Replace With"), symbol: "pencil")
                HStack {
                    Spacer()
                    Button("Replace") { Task { await project.replaceChosen() } }
                        .disabled(!groups.contains { $0.hits.contains { $0.id == search.chosen } })
                        .help("Replace the selected search result")
                    // Replace All changes every match in the project, so it waits until the filter no longer hides any.
                    let filtered = !project.navigator.searchFilter.isEmpty
                    Button("Replace All") { Task { await project.replaceAll() } }
                        .disabled(search.hitCount == 0 || filtered)
                        .help(filtered ? "Clear the filter to replace every match" : "Replace all search results")
                }
                .controlSize(.regular)
            }
            if hits > 0 {
                Text("^[\(hits) result](inflect: true) in ^[\(groups.count) file](inflect: true)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 7)
        .padding(.bottom, 6)
    }
}

struct SearchResults: View {
    let project: ProjectModel
    let field: FieldHandle
    @State private var folded: Set<String> = []

    var body: some View {
        let groups = project.shownGroups
        list(groups)
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            .safeAreaBar(edge: .top, spacing: 0) {
                FindHeader(project: project, field: field, groups: groups)
            }
            .overlay {
                if let failure = project.search.failure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.search.groups?.isEmpty == true {
                    ContentUnavailableView.search(text: project.search.searched.query)
                } else if groups.isEmpty, project.search.groups != nil {
                    NoFilterResults()
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
                    DisclosureGroup(isExpanded: $folded[lacks: group.file]) {
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

    private func file(_ group: SearchGroup) -> some View {
        Label {
            Text("\(Text(group.file.fileName).fontWeight(.medium)) \(Text(group.file.parentFolder.replacing("/", with: " ▸ ")).foregroundStyle(.secondary))")
                .lineLimit(1)
        } icon: {
            Image(systemName: project.tree.node(at: group.file)?.symbol ?? "text.document")
        }
        .help(group.file)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.file), \(Self.matches(group.hits.count))")
    }

    private func row(_ hit: SearchHit) -> some View {
        Label {
            Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)").lineLimit(3)
        } icon: {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
        }
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
