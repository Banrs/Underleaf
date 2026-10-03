import SwiftUI

/// The projects: new ones from templates, then recent ones to search and open.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    /// Single selection: every action here acts on one project.
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @FocusState private var listFocused: Bool
    @State private var query = ""

    var body: some View {
        // Over the list, which runs on under it and the toolbar with one edge effect.
        list.safeAreaBar(edge: .top) {
            if app.tex?.available == false { texMissing }
        }
        // Projects, copied in, as the Open panel says; other items are left out. One
        // opens; several stay listed under Recent.
        .fileDrop(accepts: AppModel.canOpen) { urls in
            Task {
                for url in urls { await app.importProject(from: url, open: urls.count == 1) }
            }
        }
        // Named for what the window shows, not the app (HIG, Toolbars).
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open", systemImage: "folder") { app.openingProject = true }
                    .help("Open a Folder, .tex File or .zip as a Project")
                Button("New Project", systemImage: "plus") { app.newProject() }
                    .help("New Project")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Projects")
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                templates
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            } header: {
                Text("New")
            }
            .listSectionSeparator(.hidden)
            Section {
                ForEach(shown) { project in
                    // Its own view, so a row redraws only when its rename starts or ends.
                    ProjectRow(project: project, rename: rename, ended: { listFocused = true }) { commitRename(project) }
                }
                if shown.isEmpty { empty.frame(maxWidth: .infinity).selectionDisabled() }
            } header: {
                Text("Recent")
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

    private var templates: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top) {
                ForEach(ProjectTemplate.all) { template in
                    Button { app.newProject(template.id) } label: {
                        TemplateCard(template: template)
                    }
                    .buttonStyle(.plain)
                    .help("New \(template.title) Project")
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// In the Recent section, not over the list, so the templates stay in view.
    @ViewBuilder private var empty: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                "No Projects Yet", systemImage: "text.document",
                description: Text("Choose a template above, or open or drop a folder, .tex file or .zip.")
            )
        }
    }

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await app.rename(project, to: name) }
    }

    /// Newest first, as the core lists them.
    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var texMissing: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(
                "TeX isn’t installed. Install MacTeX to compile. TeXLocal notices it once it’s there.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
            Spacer()
            GetMacTeXButton()
        }
        .padding()
    }
}

/// A recent project: its name over its main file and when it last changed.
/// While renamed, a field takes the name's place.
private struct ProjectRow: View {
    let project: ProjectInfo
    let rename: InPlaceRename<ProjectInfo.ID>
    let ended: () -> Void
    let commit: () -> Void

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if rename.id == project.id {
                    RenameField(text: Bindable(rename).name, ended: ended, commit: commit) { rename.cancel() }
                } else {
                    Text(project.name).font(.headline)
                }
                Text("\(Text(project.mainFile)) · \(Text(.currentDate, format: .reference(to: project.modified)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            // Grey, as the subtitle: the hierarchical style would tint it the accent.
            Image(systemName: "text.document")
                .font(.title2)
                .foregroundStyle(Color.secondary)
        }
    }
}

/// A button, not a link, to match the actions beside it.
struct GetMacTeXButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Get MacTeX") { openURL(URL(string: "https://tug.org/mactex/")!) }
    }
}

/// A template the core makes projects from (crates/texlocal-core templates.rs).
struct ProjectTemplate: Identifiable {
    let id: String
    let title: String
    let detail: String

    static let all = [
        ProjectTemplate(id: "blank", title: "Blank", detail: "An empty document"),
        ProjectTemplate(id: "article", title: "Article", detail: "Paper with abstract and sections"),
        ProjectTemplate(id: "report", title: "Report", detail: "Chapters and a title page"),
        ProjectTemplate(id: "beamer", title: "Presentation", detail: "Beamer slides"),
    ]
}

/// A template's card: its first page as TeX sets it, then its name.
private struct TemplateCard: View {
    let template: ProjectTemplate

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // The page the template compiles to (Assets.xcassets, one PDF each).
                Image("Template-\(template.id)")
                    .resizable()
                    .scaledToFit()
                    .border(.separator)
                    .frame(width: 120, height: 150)
                    // The card reads as its name ("Blank", not "Image, Blank").
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title).font(.headline)
                    Text(template.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Starts as Untitled, so Create is ready at once.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @State private var name = "Untitled"
    @State private var template: String
    @FocusState private var nameFocused: Bool

    init(template: String) {
        _template = State(initialValue: template)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: "New Project", message: "Its files stay in a folder on this Mac.",
                    action: "Create", enabled: !trimmed.isEmpty, failure: { "Couldn’t Create “\(trimmed)”" }) {
            try await app.create(name: trimmed, template: template)
        } fields: {
            TextField("Name", text: $name)
                .focused($nameFocused)
            Picker("Template", selection: $template) {
                ForEach(ProjectTemplate.all) { Text($0.title).tag($0.id) }
            }
        }
        .defaultFocus($nameFocused, true)
    }
}

#Preview("Template cards") {
    HStack(alignment: .top) {
        ForEach(ProjectTemplate.all) { TemplateCard(template: $0) }
    }
    .padding()
}

#Preview("Recent project") {
    List {
        ProjectRow(project: ProjectInfo(id: "thesis", name: "Thesis", mtime: Date.now.timeIntervalSince1970 * 1000 - 3_600_000,
                                        mainFile: "main.tex"),
                   rename: InPlaceRename(), ended: {}) {}
    }
    .listStyle(.inset)
}
