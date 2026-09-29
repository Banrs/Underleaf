import SwiftUI

/// The projects: new ones from templates, then recent ones to search and open.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    /// Single selection: every action here acts on one project.
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @State private var query = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if app.tex?.available == false {
                texMissing
                Divider()
            }
            list
        }
        // Copied in, as the Open panel says; anything else is refused.
        .fileDrop(accepts: AppModel.canOpen, targeted: { dropTargeted = $0 }) { urls in
            guard let url = urls.first else { return }
            Task { await app.importProject(from: url) }
        }
        .overlay(alignment: .bottom) {
            if dropTargeted {
                Label("Drop to copy it into your projects", systemImage: "plus.circle.fill")
                    .padding()
                    .glassEffect(.regular, in: .capsule)
                    .padding()
                    .allowsHitTesting(false)
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
                    ProjectRow(project: project, rename: rename) { commitRename(project) }
                }
                if shown.isEmpty { empty.selectionDisabled() }
            } header: {
                Text("Recent")
            }
            .listSectionSeparator(.hidden)
        }
        .headerProminence(.increased)
        .listStyle(.inset)
        .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
            if let project = app.projects.first(where: { ids.contains($0.id) }) {
                Button("Open") { Task { await app.open(project.id) } }
                Divider()
                ItemMenuItems(rename: { rename.begin(project.id, name: project.name) },
                              showInFinder: { app.revealProject(project) },
                              moveToTrash: { Task { await app.delete(project) } })
            }
        } primaryAction: { ids in
            if let id = ids.first { Task { await app.open(id) } }
        }
        .offersToTrash(rename.id == nil ? selection.map(TrashItem.project) : nil)
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
                "No Projects Yet", systemImage: "doc.text",
                description: Text("Choose a template above to start writing. Your files never leave this Mac.")
            )
        }
    }

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await app.rename(project, to: name) }
    }

    /// Newest first, as `AppModel.refresh` sorts them.
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
    let commit: () -> Void

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Typography.subtitleSpacing) {
                if rename.id == project.id {
                    RenameField(text: Bindable(rename).name, commit: commit) { rename.cancel() }
                } else {
                    Text(project.name).font(Typography.itemTitle)
                }
                Text("\(Text(project.mainFile)) · \(Text(.currentDate, format: .reference(to: project.modified)))")
                    .font(Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.secondary)
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
    let detail: String
    let page: Page

    static let all = [
        ProjectTemplate(id: "blank", title: "Blank", detail: "An empty document", page: .blank),
        ProjectTemplate(id: "article", title: "Article", detail: "Paper with abstract and sections", page: .article),
        ProjectTemplate(id: "report", title: "Report", detail: "Chapters and a title page", page: .report),
        ProjectTemplate(id: "beamer", title: "Presentation", detail: "Beamer slides", page: .slides),
    ]
}

/// A template's card: a drawing of its first page, then its name.
private struct TemplateCard: View {
    let template: ProjectTemplate
    /// A US Letter page, 120 pt wide; its corner is drawn to look like paper, not to the kit.
    private static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                page
                VStack(alignment: .leading, spacing: Typography.subtitleSpacing) {
                    Text(template.title).font(Typography.itemTitle)
                    Text(template.detail)
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .frame(width: Self.page.width, alignment: .leading)
                }
            }
        }
        .contentShape(.rect)
        // The focus ring on the group box's corners, not a square.
        .contentShape(.focusEffect, .rect(cornerRadius: 12, style: .continuous)) // UI kit: Group Boxes
        .accessibilityElement(children: .combine)
    }

    private var page: some View {
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
                heading
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

    private var heading: some View {
        HStack { bar(40, 3); Spacer() }.padding(.horizontal, 16)
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        Capsule().fill(.tertiary).frame(width: width, height: height)
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
                    action: "Create", enabled: !trimmed.isEmpty) {
            let (name, template) = (trimmed, template)
            Task { await app.create(name: name, template: template) }
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
                   rename: InPlaceRename()) {}
    }
    .listStyle(.inset)
}
