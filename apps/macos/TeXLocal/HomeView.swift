import SwiftUI

/// The projects: new ones from templates, then all of them to search and open.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    /// Single selection: every action here acts on one project.
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @FocusState private var listFocused: Bool
    @FocusState private var searching: Bool
    @State private var query = ""
    @AppStorage("dismissedTeXTip") private var dismissedTeXTip = false
    /// What has been opening or copying for over 300 ms: a quicker one shows nothing.
    @State private var slow: Set<String> = []

    var body: some View {
        // Over the list, which runs on under it and the toolbar with one edge effect.
        Group {
            if let problem = app.libraryProblem { unavailable(problem) } else { list }
        }
        .safeAreaBar(edge: .top) {
            if app.tex?.available == false, !dismissedTeXTip { texMissing }
        }
        // Projects, copied in, as the Open panel says; other items are left out. One
        // opens; several stay listed under All Projects.
        .fileDrop(accepts: { app.libraryProblem == nil && AppModel.canOpen($0) }) { urls in
            Task {
                for url in urls { await app.importProject(from: url, open: urls.count == 1) }
            }
        }
        // Named for what the window shows, not the app (HIG, Toolbars).
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open", systemImage: "folder") { app.openingProject = true }
                    .help("Open a folder, .tex file or .zip as a project")
                    .disabled(app.libraryProblem != nil)
                Button("New Project", systemImage: "plus") { app.newProject() }
                    .help("Start a new project")
                    .disabled(app.libraryProblem != nil)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Projects")
        .searchFocused($searching)
        // Edit › Find Project…
        .onChange(of: app.searchFocusToken) { searching = true }
        .task(id: app.opening) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            slow = Set(app.opening)
        }
    }

    /// Instead of the list, with no alert as the app starts (HIG, Alerts).
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
            // No section header: the list pins its first one with a rule the full width
            // of the window, over cards that have no rule of their own.
            VStack(alignment: .leading, spacing: 8) {
                Text("New").font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
                templates
            }
            .selectionDisabled()
            .listRowSeparator(.hidden)
            // The buttons bring their own 10 pt edge.
            .listRowInsets(EdgeInsets())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New")
            Section {
                // An item being copied into the library, in the place its project will take.
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
        // Return opens the chosen project, as in Xcode's project list; double-clicking does too.
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

    /// Wrapping, so no card is cut off in a narrow window; 4 pt apart, so the hover shapes of
    /// buttons this size don't touch (HIG, Buttons).
    private var templates: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: TemplateCard.width, maximum: TemplateCard.width), spacing: 4, alignment: .top)],
                  alignment: .leading, spacing: 4) {
            ForEach(ProjectTemplate.all) { template in
                Button { app.newProject(template.id) } label: {
                    TemplateCard(template: template)
                }
                .buttonStyle(TemplateButtonStyle())
                .help("Start a project from the \(template.title) template")
            }
        }
    }

    /// In the projects' section, not over the list, so the templates stay in view.
    @ViewBuilder private var empty: some View {
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

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await app.rename(project, to: name) }
    }

    /// Being opened or copied in for a while.
    private var working: Set<String> { slow.intersection(app.opening) }

    /// Items being copied in, which are not projects yet.
    private var copying: [String] {
        let ids = Set(app.projects.map(\.id))
        return query.isEmpty ? app.opening.filter { working.contains($0) && !ids.contains($0) } : []
    }

    /// Newest first, as the core lists them.
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

/// A project: its name over its main file and when it last changed.
/// While renamed, a field takes the name's place; while it opens, a spinner follows.
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

/// What the project rows share: the document's icon, a name over a detail line, and a spinner
/// with the accessibility name `progress` at the trailing edge while there is one.
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

/// A button, not a link, to match the actions beside it.
struct GetMacTeXButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Get MacTeX") { openURL(URL(string: "https://tug.org/mactex/")!) }
    }
}

/// A template the core makes projects from (crates/texlocal-core templates.rs).
struct ProjectTemplate: Identifiable {
    enum Page { case blank, article, report, slides }

    let id: String
    let title: String
    let page: Page

    static let all = [
        ProjectTemplate(id: "blank", title: "Blank", page: .blank),
        ProjectTemplate(id: "article", title: "Article", page: .article),
        ProjectTemplate(id: "report", title: "Report", page: .report),
        ProjectTemplate(id: "beamer", title: "Presentation", page: .slides),
    ]
}

/// An image button (HIG, Buttons): no border at rest, 10 pt from the content to the
/// clickable edge, and a fill under the pointer that deepens while pressed.
private struct TemplateButtonStyle: ButtonStyle {
    static let edge: CGFloat = 10
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .padding(Self.edge)
            .background(.fill.opacity(configuration.isPressed ? 1 : hovered ? 0.5 : 0), in: shape)
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onHover { hovered = $0 }
    }
}

/// A template's card: a drawing of its first page with its name under it, as in a template chooser.
private struct TemplateCard: View {
    let template: ProjectTemplate
    /// A US Letter page, 120 pt wide; its corner is drawn to look like paper, not to the kit.
    private static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    /// With the button's edge on both sides.
    static let width = page.width + 2 * TemplateButtonStyle.edge
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            PagePreview(page: template.page)
                .frame(width: Self.page.width, height: Self.page.height)
                // White paper in either appearance, dimmed a little in dark mode;
                // the drawing in light colours, which are made for paper.
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1),
                            in: .rect(cornerRadius: Self.corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(.separator)
                }
                .environment(\.colorScheme, .light)
                // The card reads as its name ("Blank", not "Add, Blank").
                .accessibilityHidden(true)
            Text(template.title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Bars where the text would be, laid out like the template's first page.
/// Its numbers are the drawing's, in points of the 120 pt page, not layout.
private struct PagePreview: View {
    let page: ProjectTemplate.Page

    var body: some View {
        switch page {
        case .blank:
            Image(systemName: "plus")
                .font(.largeTitle)
                .fontWeight(.light)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .article:
            VStack(spacing: 5) {
                bar(64, 5).padding(.top, 16)
                bar(40, 3)
                bar(52, 3).padding(.bottom, 6)
                ForEach(0..<2, id: \.self) { _ in bar(78, 2) }
                bar(60, 2).padding(.bottom, 4)
                HStack { bar(40, 3); Spacer() }.padding(.horizontal, 16)
                ForEach(0..<4, id: \.self) { _ in bar(88, 2) }
                bar(50, 2)
                Spacer(minLength: 0)
            }
        case .report:
            VStack(spacing: 6) {
                Spacer()
                bar(70, 6)
                bar(46, 3)
                bar(36, 3)
                Spacer()
                bar(30, 2).padding(.bottom, 18)
            }
        case .slides:
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    Rectangle().fill(.tint.opacity(0.6)).frame(height: 14)
                    bar(60, 4)
                    bar(40, 3)
                    Spacer()
                }
                .frame(width: 104, height: 58)
                .overlay(Rectangle().strokeBorder(.separator))
                Spacer()
            }
        }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        Capsule().fill(.tertiary).frame(width: width, height: height)
    }
}

/// Starts as the first Untitled not taken, as Finder numbers a new folder, so Create is ready at once.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @State private var name: String
    @State private var template: String
    @FocusState private var nameFocused: Bool

    init(template: String, taken: [String]) {
        _template = State(initialValue: template)
        let names = Set(taken.map { $0.lowercased() })
        _name = State(initialValue: (1...).lazy.map { $0 == 1 ? "Untitled" : "Untitled".numbered($0) }.first { !names.contains($0.lowercased()) } ?? "Untitled")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: "New Project", message: "Saved in \((Core.libraryFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath).",
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

#Preview("Project") {
    List {
        ProjectRow(project: ProjectInfo(id: "thesis", name: "Thesis", mtime: Date.now.timeIntervalSince1970 * 1000 - 3_600_000,
                                        mainFile: "main.tex"),
                   working: false, rename: InPlaceRename(), ended: {}) {}
    }
    .listStyle(.inset)
}
