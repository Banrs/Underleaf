import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @FocusState private var listFocused: Bool
    @FocusState private var searching: Bool
    @State private var query = ""
    @AppStorage("dismissedTeXTip") private var dismissedTeXTip = false
    @State private var slow: Set<String> = []

    var body: some View {
        Group {
            if let problem = app.libraryProblem { unavailable(problem) } else { list }
        }
        .safeAreaBar(edge: .top) {
            if app.tex?.available == false, !dismissedTeXTip { texMissing }
        }
        .fileDrop(accepts: { app.libraryProblem == nil && AppModel.canOpen($0) }) { urls in
            Task {
                for url in urls { await app.importProject(from: url, open: urls.count == 1) }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open", systemImage: "folder") { app.openingProject = true }
                    .help("Open a folder, .tex file or .zip as a project")
                    .disabled(app.libraryProblem != nil)
                Button("New Project", systemImage: "plus") { app.newProject() }
                    .help("Name a project and choose its template")
                    .disabled(app.libraryProblem != nil)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Projects")
        .searchFocused($searching)
        .onChange(of: app.searchFocusToken) { searching = true }
        .task(id: app.opening) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            slow = Set(app.opening)
        }
    }

    private func unavailable(_ problem: AppAlert) -> some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(problem.message)
        } actions: {
            Button("Try Again") { Task { await app.retryLibrary() } }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                ForEach(copying, id: \.self) { name in
                    ProjectLabel(detail: Text("Copying…"), progress: "Copying") { Text(name).font(.headline) }
                }
                ForEach(shown) { project in
                    // Its own view, so a row redraws only when its rename starts or ends.
                    ProjectRow(project: project, working: working.contains(project.id), rename: rename,
                               ended: { listFocused = true }) { commitRename(project) }
                }
                if app.projectsLoaded, shown.isEmpty { empty.frame(maxWidth: .infinity).selectionDisabled() }
            } header: {
                Text("All Projects")
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
            if let project = app.projects.first(where: { ids.contains($0.id) }) {
                Button("Open") { Task { await app.open(project.id) } }
                Divider()
                ItemMenuItems(actions: actions(project))
            }
        } primaryAction: { ids in
            if let id = ids.first { Task { await app.open(id) } }
        }
        .onKeyPress(.return) {
            guard rename.id == nil, let id = selection else { return .ignored }
            Task { await app.open(id) }
            return .handled
        }
        .focused($listFocused)
        .offersActions(for: listFocused && rename.id == nil ? selection : nil) { id in
            shown.first { $0.id == id }.map(actions)
        }
    }

    private func actions(_ project: ProjectInfo) -> ItemActions {
        ItemActions(rename: { rename.begin(project.id, name: project.name) },
                    showInFinder: { app.revealProject(project) },
                    moveToTrash: { Task { await app.delete(project) } })
    }

    @ViewBuilder private var empty: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "text.document")
            } description: {
                Text("Create a project, or open or drop a folder, .tex file or .zip.")
            } actions: {
                Button(MenuCommand.projectNew.title) { app.newProject() }
                Button("Open…") { app.openingProject = true }
            }
        }
    }

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await app.rename(project, to: name) }
    }

    private var working: Set<String> { slow.intersection(app.opening) }

    private var copying: [String] {
        let ids = Set(app.projects.map(\.id))
        return query.isEmpty ? app.opening.filter { working.contains($0) && !ids.contains($0) } : []
    }

    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var texMissing: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(
                "MacTeX isn’t installed. Install it to compile; TeXLocal finds it afterwards.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
            Spacer()
            GetMacTeXButton()
            Button("Dismiss", systemImage: "xmark") { dismissedTeXTip = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide this message")
        }
        .padding()
    }
}

private struct ProjectRow: View {
    let project: ProjectInfo
    let working: Bool
    let rename: InPlaceRename<ProjectInfo.ID>
    let ended: () -> Void
    let commit: () -> Void

    var body: some View {
        ProjectLabel(detail: Text("\(Text(project.mainFile)) · \(Text(.currentDate, format: .reference(to: project.modified)))"),
                     progress: working ? "Opening" : nil) {
            if rename.id == project.id {
                RenameField(text: Bindable(rename).name, ended: ended, commit: commit) { rename.cancel() }
            } else {
                Text(project.name).font(.headline)
            }
        }
    }
}

private struct ProjectLabel<Name: View>: View {
    let detail: Text
    let progress: String?
    @ViewBuilder let name: Name

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    name
                    detail.font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                // Grey, as the detail: the hierarchical style would tint it the accent.
                Image(systemName: "text.document")
                    .font(.title2)
                    .foregroundStyle(Color.secondary)
            }
            if let progress {
                Spacer()
                ProgressView().controlSize(.small).accessibilityLabel(progress)
            }
        }
    }
}

struct GetMacTeXButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Get MacTeX") { openURL(URL(string: "https://tug.org/mactex/")!) }
    }
}

struct TeXpressoGuideButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Install Guide") {
            openURL(URL(string: "https://github.com/Banrs/Underleaf/blob/main/docs/texpresso.md")!)
        }
    }
}

enum ProjectTemplate: String, CaseIterable, Identifiable {
    case blank, article, report, beamer

    static let standard = ProjectTemplate.article

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Blank"
        case .article: "Article"
        case .report: "Report"
        case .beamer: "Presentation"
        }
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @State private var name: String
    @State private var template: ProjectTemplate
    @FocusState private var nameFocused: Bool

    init(template: ProjectTemplate, taken: [String]) {
        _template = State(initialValue: template)
        let names = Set(taken.map { $0.lowercased() })
        _name = State(initialValue: (1...).lazy.map { $0 == 1 ? "Untitled" : "Untitled \($0)" }.first { !names.contains($0.lowercased()) } ?? "Untitled")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: "New Project", message: "Saved in \(Core.libraryPath).",
                    action: "Create", enabled: !trimmed.isEmpty, failure: { "Couldn’t Create “\(trimmed)”" }) {
            try await app.create(name: trimmed, template: template)
        } fields: {
            // At a grouped form's trailing edge AppKit shows a space typed last only once a letter follows (27.2), so the text leads in
            // a field as wide as the name: the row keeps it at its trailing edge, and each space moves the name as it is typed.
            LabeledContent("Name") {
                NameWidth {
                    TextField("Name", text: $name, prompt: Text("Required"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .focused($nameFocused)
                }
            }
            Picker("Template", selection: $template) {
                ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) }
            }
        }
        .defaultFocus($nameFocused, true)
    }
}

/// Asked for its ideal it claims none, so a long name scrolls in its row and the form never moves it under its label as it is typed.
private struct NameWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let text = subviews[0].sizeThatFits(.unspecified).width
        return subviews[0].sizeThatFits(ProposedViewSize(width: min(text, proposal.width ?? 0), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

#Preview("Project") {
    List {
        ProjectRow(project: ProjectInfo(id: "thesis", name: "Thesis", mtime: Date.now.timeIntervalSince1970 * 1000 - 3_600_000,
                                        mainFile: "main.tex"),
                   working: false, rename: InPlaceRename(), ended: {}) {}
    }
    .listStyle(.inset)
}
