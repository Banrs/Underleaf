import SwiftUI

/// The start window, as Word's and Overleaf's open: new documents from
/// templates across the top, each with a preview of its page, then recent
/// projects as a list — name, main file, when last changed — to search
/// and open.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Set<ProjectInfo.ID> = []
    /// The project whose name is being edited in place, and the name so far.
    @State private var renaming: ProjectInfo.ID?
    @State private var newName = ""
    @State private var deleting: ProjectInfo?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            if app.tex?.available == false {
                texMissing
                Divider()
            }
            templates
            Divider()
            recents
        }
        // Named for what the window shows, not the app (HIG, Toolbars).
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open", systemImage: "folder") { app.chooseProjectToOpen() }
                    .help("Open a Folder, .tex File or .zip as a Project")
                Button("New Project", systemImage: "plus") { app.newProject() }
                    .help("New Project")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Projects")
        .task(id: app.tex?.available) { await app.watchForTeX() }
        // `presenting`, so the title keeps its name while the dialog closes.
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?",
            isPresented: Binding(presenting: $deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { project in
            // Not destructive-styled: moving to the Trash was chosen, and the
            // Trash gives it back (HIG, Alerts).
            Button("Move to Trash") { Task { await app.delete(project) } }
        } message: { _ in
            Text("You can restore it from the Trash.")
        }
    }

    /// The window's margin: where the inset table starts its column titles
    /// and row content (its 10 pt inset, then the cell's 8 pt), measured on
    /// macOS 27. The section titles and template cards take the same edge,
    /// so New, Recent, Name and the rows start on one line.
    private static let margin: CGFloat = 18

    // ---------- new ----------

    private var templates: some View {
        VStack(alignment: .leading) {
            Text("New")
                .font(Typography.sectionTitle)
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
        .padding(Self.margin)
    }

    // ---------- recent ----------

    private var recents: some View {
        VStack(alignment: .leading) {
            Text("Recent")
                .font(Typography.sectionTitle)
                .padding([.horizontal, .top], Self.margin)
            List(shown, selection: $selection) { project in
                // A view of its own that reads the rename through bindings:
                // the list redraws a row only when its value changes.
                ProjectRow(project: project, renaming: $renaming, newName: $newName) {
                    commitRename(project)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
                if let project = app.projects.first(where: { ids.contains($0.id) }) {
                    Button("Open") { Task { await app.open(project.id) } }
                    Divider()
                    // Edited in place, as Finder renames: no dialog, so no
                    // ellipsis.
                    Button("Rename") {
                        newName = project.name
                        renaming = project.id
                    }
                    Button("Show in Finder") { app.revealProject(project) }
                    Divider()
                    Button("Move to Trash") { deleting = project }
                }
            } primaryAction: { ids in
                if let id = ids.first { Task { await app.open(id) } }
            }
            // Delete, as Finder's ⌘⌫ and every list's Delete key do.
            .onDeleteCommand {
                if let project = app.projects.first(where: { selection.contains($0.id) }) { deleting = project }
            }
            .overlay {
                if !query.isEmpty, shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if app.projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects Yet", systemImage: "doc.text",
                        description: Text("Choose a template above to start writing. Your files never leave this Mac.")
                    )
                }
            }
        }
    }

    private func commitRename(_ project: ProjectInfo) {
        guard renaming == project.id else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != project.name else { return }
        Task { await app.rename(project, to: name) }
    }

    private var shown: [ProjectInfo] {
        let matching = query.isEmpty
            ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matching.sorted { $0.mtime > $1.mtime }
    }

    private var texMissing: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(
                "TeX isn’t installed. Install MacTeX to compile; TeXLocal notices it once it’s there.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
            Spacer()
            GetMacTeXButton()
        }
        .padding(Self.margin)
    }
}

/// A recent project as Xcode's and Keynote's welcome windows list them: its
/// name over its main file and when it last changed. While it is renamed,
/// a field takes the name's place: Return or clicking away renames, Escape
/// leaves it as it was.
private struct ProjectRow: View {
    let project: ProjectInfo
    @Binding var renaming: ProjectInfo.ID?
    @Binding var newName: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if renaming == project.id {
                    TextField("Name", text: $newName)
                        .labelsHidden()
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { renaming = nil }
                        .onChange(of: focused) { was, now in
                            if was, !now { commit() }
                        }
                        // Once the context menu has closed and handed the
                        // list its focus back, or the list takes it from the
                        // field.
                        .task {
                            try? await Task.sleep(for: .milliseconds(150))
                            focused = true
                        }
                } else {
                    Text(project.name).font(.headline)
                }
                Text("\(project.mainFile) · \(project.modified.formatted(.relative(presentation: .named)))")
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

/// Where to get TeX: the start window's notice and the PDF pane link here.
let macTeXURL = URL(string: "https://tug.org/mactex/")!

/// Opens MacTeX's page: a button, as the actions beside it are, not a link.
struct GetMacTeXButton: View {
    @Environment(\.openURL) private var openURL
    var prominent = false

    var body: some View {
        if prominent {
            Button("Get MacTeX") { openURL(macTeXURL) }.buttonStyle(.borderedProminent)
        } else {
            Button("Get MacTeX") { openURL(macTeXURL) }
        }
    }
}

/// A template the core can make a project from (crates/texlocal-core
/// templates.rs), with how its first page looks.
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

/// A template's card, in the system's group box: a drawing of its first
/// page, then its name.
private struct TemplateCard: View {
    let template: ProjectTemplate
    /// A drawing of a Letter page: the thumbnail's size and its corners.
    private static let page = CGSize(width: 120, height: 156)
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GroupBox {
            content
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: BarMetrics.groupSpacing) {
            PagePreview(page: template.page)
                .frame(width: Self.page.width, height: Self.page.height)
                // Paper is white in either appearance, dimmed a little in
                // dark mode as the HIG dims a white PDF page; its drawing in
                // the light appearance's colours, which are drawn for paper.
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1),
                            in: .rect(cornerRadius: Self.corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(.separator)
                }
                .environment(\.colorScheme, .light)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).font(.headline)
                Text(template.detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: Self.page.width, alignment: .leading)
            }
        }
    }
}

/// Grey bars where the text would be, laid out like the template's first
/// page (or first slide), in semantic fills and the accent.
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

/// A new project: its name (Untitled to begin with, so Create is ready)
/// and template (the card chosen, or Article for ⌘N).
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @State private var name = "Untitled"
    @State private var template = "article"
    @FocusState private var nameFocused: Bool

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
        .onAppear {
            template = app.newProjectTemplate
            nameFocused = true
        }
    }
}
