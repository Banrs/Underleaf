import SwiftUI

/// Find in Project's matches by file, or Find Usages' under the name; a hit opens as a jump, which Go Back returns from.
struct SearchResults: View {
    let project: ProjectModel
    #if os(macOS)
    @State private var hit: SearchHit.ID?
    /// At the inset and spacing the search field's accessory has (measured).
    private static let inset: (side: CGFloat, below: CGFloat) = (10, 9)
    #else
    /// Back to the source, where the split has collapsed to one column.
    let showSource: () -> Void
    private static let inset: (side: CGFloat, below: CGFloat) = (20, 8)
    #endif

    var body: some View {
        list
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            // Usages aren't the query's matches, which Replace All would replace.
            .safeAreaBar(edge: .top, spacing: 0) {
                Group {
                    if let usages = project.search.usages {
                        Text(String(localized: "Usages of \(usages.name)"))
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        replaceBar
                    }
                }
                .padding(.horizontal, Self.inset.side)
                .padding(.bottom, Self.inset.below)
            }
            .overlay {
                if let failure = project.search.failure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.search.groups?.isEmpty == true {
                    ContentUnavailableView.search(text: project.search.searched)
                }
            }
    }

    #if os(macOS)
    private var list: some View {
        List(selection: $hit) { sections { row($0) } }
            // A new query can reuse a hit's ID: the first click on the new hit opens it.
            .onChange(of: project.search.query, initial: true) { hit = nil }
            .onChange(of: hit) { _, id in open(id, focus: false) }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
    }

    /// Under the search field, as Xcode's Find navigator in Replace mode.
    private var replaceBar: some View {
        HStack {
            SearchField(text: Bindable(project.search).replacement, prompt: "Replace With", symbol: "arrow.2.squarepath")
            replaceAll
        }
    }
    #else
    private var list: some View {
        List {
            sections { hit in
                Button {
                    showSource()
                    open(hit.id, focus: true)
                } label: { row(hit) }
                .foregroundStyle(.primary)
            }
        }
    }

    private var replaceBar: some View {
        HStack {
            TextField("Replace With", text: Bindable(project.search).replacement)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            replaceAll
        }
    }
    #endif

    private var replaceAll: some View {
        Button("Replace All") { Task { await project.replaceAll() } }
            .disabled(project.search.hitCount == 0)
    }

    private func sections<Row: View>(@ViewBuilder _ hit: @escaping (SearchHit) -> Row) -> some View {
        ForEach(project.search.groups ?? []) { group in
            Section {
                ForEach(group.hits) { hit($0) }
            } header: {
                HStack {
                    Text(group.file).truncationMode(.middle)
                    Spacer()
                    Text(group.hits.count, format: .number).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.file), \(Self.matches(group.hits.count))")
            }
        }
    }

    private func row(_ hit: SearchHit) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)")
                .lineLimit(2)
            Spacer(minLength: 4)
            Text("\(hit.line)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Line \(hit.line)")
        }
        .accessibilityElement(children: .combine)
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
    /// The project's search as its query changes, once typing pauses, as each search reads every file. VoiceOver hears the
    /// count, as it does the PDF's find count.
    func searching(_ project: ProjectModel) -> some View {
        task(id: project.search.query) {
            if project.search.isSearching { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await project.search.run(in: project.session)
            guard !Task.isCancelled, project.search.groups != nil, project.search.failure == nil else { return }
            let count = project.search.hitCount
            project.notices.announce(count == 0 ? String(localized: "Not found") : SearchResults.matches(count), queued: true)
        }
    }
}
