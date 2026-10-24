import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @FocusState private var listFocused: Bool
    @FocusState private var searching: Bool
    @State private var query = ""
    /// Still at work 300 ms on: a quick open or copy shows no spinner.
    @State private var slowOpening: String?
    @State private var slowImports: [URL] = []

    var body: some View {
        Group { if let problem = app.libraryProblem { unavailable(problem) } else { list } }
        .fileDrop(accepts: { app.libraryProblem == nil && AppModel.canOpen($0) }) { urls in Task { await app.open(urls) } }
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
            if !copied { do { try await Task.sleep(for: .milliseconds(300)) } catch { return } }
            slowOpening = app.opening
        }
        .task(id: app.importing) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            slowImports = app.importing
        }
    }

    private var list: some View {
        List(selection: $selection) {
            // No section header: the list pins its first one with a rule the window's width.
            VStack(alignment: .leading, spacing: 8) {
                Text("New").font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
                // The pages under the header and level with the projects' icons; the hover shapes reach past them.
                templates.padding(.horizontal, -TemplateButtonStyle.edge)
            }
            .selectionDisabled()
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New")
            Section {
                ForEach(copying, id: \.self) { url in
                    ProjectLabel(detail: Text("Opening…"), progress: "Opening") { Text(url.lastPathComponent).font(.headline) }
                }
                ForEach(shown) { project in
                    // Its own view, so a row redraws only as its rename starts or ends.
                    ProjectRow(project: project, working: project.id == app.opening && (project.id == slowOpening || copied),
                               rename: rename, ended: { listFocused = true }) { commitRename(project) }
                }
                if app.projectsLoaded, shown.isEmpty { noProjects.frame(maxWidth: .infinity).selectionDisabled() }
            } header: { Text("All Projects") }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
            if let project = app.projects.first(where: { ids.contains($0.id) }) {
                Button("Open") { Task { await app.open(project.id) } }
                Divider()
                if project.opened {
                    Button { actions(project).showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                        .disabled(project.missing)
                    Divider()
                    Button { Task { await app.forget(project) } } label: { Label("Remove from List", systemImage: "minus.circle") }
                } else {
                    Button { Task { if let copy = await app.duplicate(project) { selection = copy } } } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    ItemMenuItems(actions: actions(project))
                }
            }
        } primaryAction: { ids in if let id = ids.first { Task { await app.open(id) } } }
        .onKeyPress(.return) {
            guard rename.id == nil, let id = selection else { return .ignored }
            Task { await app.open(id) }
            return .handled
        }
        .focused($listFocused)
        .offersActions(for: listFocused && rename.id == nil ? selection : nil) { id in shown.first { $0.id == id }.map(actions) }
        // The latest, as Xcode's welcome window selects it, so Return opens it again.
        .onChange(of: app.projectsLoaded, initial: true) { if selection == nil { selection = app.projects.first?.id } }
    }

    private func actions(_ project: ProjectInfo) -> ItemActions {
        ItemActions(rename: project.opened ? nil : { rename.begin(project.id, name: project.name) },
                    showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) },
                    moveToTrash: project.opened ? nil : { Task { await app.delete(project) } })
    }

    /// Wrapping, so no card is cut off in a narrow window; 4 pt apart, so the hover shapes don't touch (HIG, Buttons).
    private var templates: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: TemplateCard.width, maximum: TemplateCard.width), spacing: 4, alignment: .top)],
                  alignment: .leading, spacing: 4) {
            ForEach(ProjectTemplate.allCases) { template in
                Button { app.newProject(template) } label: { TemplateCard(template: template) }
                .buttonStyle(TemplateButtonStyle())
                .help("Start a project from the \(template.title) template")
            }
        }
    }

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await app.rename(project, to: name) }
    }

    private var copying: [URL] { query.isEmpty ? slowImports.filter(app.importing.contains) : [] }

    /// A copy shown has ended: the project opening is at work in its own row.
    private var copied: Bool { slowImports.contains { !app.importing.contains($0) } }

    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
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

    /// In the section, not over the list, so the templates stay in view.
    @ViewBuilder private var noProjects: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "text.document")
            } description: {
                Text("Choose a template above, or open or drop a folder, .tex file or .zip.")
            } actions: {
                Button("Open…") { app.openingProject = true }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectInfo
    let working: Bool
    let rename: InPlaceRename<ProjectInfo.ID>
    let ended, commit: () -> Void

    var body: some View {
        ProjectLabel(detail: detail, symbol: project.opened ? "folder" : "text.document", dimmed: project.missing,
                     progress: working ? "Opening" : nil) {
            if rename.id == project.id {
                RenameField(text: Bindable(rename).name, ended: ended, commit: commit) { rename.cancel() }
            } else {
                Text(project.name).font(.headline)
            }
        }
    }

    /// An opened folder's path, as Xcode's welcome window lists projects.
    private var detail: Text {
        guard project.opened else {
            return Text("\(Text(project.mainFile)) · \(Text(.currentDate, format: .reference(to: project.modified)))")
        }
        let path = (project.path as NSString).abbreviatingWithTildeInPath
        return project.missing ? Text("\(path) · Not Found") : Text(path)
    }
}

private struct ProjectLabel<Name: View>: View {
    let detail: Text
    var symbol = "text.document"
    var dimmed = false
    let progress: String?
    @ViewBuilder let name: Name

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    name.foregroundStyle(dimmed ? HierarchicalShapeStyle.tertiary : .primary)
                    detail.font(.subheadline).foregroundStyle(dimmed ? HierarchicalShapeStyle.tertiary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } icon: {
                // Grey, as the detail: the hierarchical style would tint it the accent.
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(dimmed ? Color(nsColor: .tertiaryLabelColor) : .secondary)
            }
            if let progress {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(progress)
            }
        }
    }
}

/// A drawing of the template's first page with its name under it.
private struct TemplateCard: View {
    let template: ProjectTemplate
    /// A US Letter page, 120 pt wide, its corner drawn to look like paper.
    private static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    static let width = page.width + 2 * TemplateButtonStyle.edge
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 8) {
            PagePreview(template: template)
                .frame(width: Self.page.width, height: Self.page.height)
                // White paper in either appearance, dimmed a little in dark mode.
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1), in: paper)
                .overlay { paper.strokeBorder(.separator) }
                .environment(\.colorScheme, .light)
                // The card reads as its name ("Blank", not "Add, Blank").
                .accessibilityHidden(true)
            Text(template.title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An image button (HIG, Buttons): no border at rest, 10 pt to the clickable edge, a fill under the pointer that deepens
/// while pressed.
private struct TemplateButtonStyle: ButtonStyle {
    static let edge: CGFloat = 10
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .padding(Self.edge)
            .background {
                if configuration.isPressed { shape.fill(.fill.secondary) } else if hovered { shape.fill(.fill.tertiary) }
            }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onHover { hovered = $0 }
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @State var draft: NewProjectDraft
    @FocusState private var nameFocused: Bool

    private var trimmed: String { draft.name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: "New Project", message: "Saved in \(Core.libraryPath).",
                    action: "Create", enabled: !trimmed.isEmpty, failure: { "Couldn’t Create “\(trimmed)”" }) {
            try await app.create(name: trimmed, template: draft.template)
        } fields: {
            TextField("Name", text: $draft.name, prompt: Text("Required"))
                .focused($nameFocused)
            Picker("Template", selection: $draft.template) { ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) } }
        }
        .defaultFocus($nameFocused, true)
    }
}
