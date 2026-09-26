import SwiftUI

/// The start window, as Word's and Overleaf's open: new documents from
/// templates across the top, each with a preview of its page, then recent
/// projects as a table — name, main file, when last changed — to search,
/// sort and open.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Set<ProjectInfo.ID> = []
    @State private var sortOrder = [KeyPathComparator(\ProjectInfo.mtime, order: .reverse)]
    @State private var renaming: ProjectInfo?
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
            ToolbarItem(placement: .primaryAction) {
                Button("New Project", systemImage: "plus") { newProject("article") }
                    .help("New Project")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Projects")
        .task(id: app.tex?.available) { await app.watchForTeX() }
        .alert("Rename Project", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { project in
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await app.rename(project, to: trimmedName) } }
                .disabled(trimmedName.isEmpty || trimmedName == project.name)
        }
        // `presenting`, so the title keeps its name while the dialog closes.
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { project in
            Button("Move to Trash", role: .destructive) { Task { await app.delete(project) } }
        } message: { _ in
            Text("You can restore it from the Trash.")
        }
    }

    /// The window's margin: where the inset table starts its column titles
    /// and row content (its 10 pt inset, then the cell's 8 pt), measured on
    /// macOS 27. The section titles and template cards take the same edge,
    /// so New, Recent, Name and the rows start on one line.
    private static let margin: CGFloat = 18

    private func newProject(_ template: String) {
        app.newProjectTemplate = template
        app.showNewProject = true
    }

    // ---------- new ----------

    private var templates: some View {
        VStack(alignment: .leading) {
            Text("New")
                .font(Typography.sectionTitle)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.margin) {
                    ForEach(ProjectTemplate.all) { template in
                        Button { newProject(template.id) } label: {
                            TemplateCard(template: template)
                        }
                        // A plain system button: it dims while pressed and
                        // takes the focus ring with keyboard navigation.
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
            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { project in
                    Label(project.name, systemImage: "doc.text")
                }
                .width(min: 180, ideal: 320)
                TableColumn("Main File", value: \.mainFile) { project in
                    Text(project.mainFile).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 160)
                TableColumn("Modified", value: \.mtime) { project in
                    Text(project.modified, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 140)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
                if let project = app.projects.first(where: { ids.contains($0.id) }) {
                    Button("Open") { Task { await app.open(project.id) } }
                    Divider()
                    Button("Rename…") { newName = project.name; renaming = project }
                    Button("Show in Finder") { app.revealProject(project) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { deleting = project }
                }
            } primaryAction: { ids in
                if let id = ids.first { Task { await app.open(id) } }
            }
            // Delete, as Finder's ⌘⌫ and every list's Delete key do.
            .onDeleteCommand { if let project = selected { deleting = project } }
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

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    private var shown: [ProjectInfo] {
        let matching = query.isEmpty
            ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matching.sorted(using: sortOrder)
    }

    private var selected: ProjectInfo? {
        app.projects.first { selection.contains($0.id) }
    }

    private var texMissing: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(
                "TeX isn’t installed. Install MacTeX to compile; TeXLocal notices it once it’s there.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
            Spacer()
            Link("Get MacTeX", destination: macTeXURL)
        }
        .padding(Self.margin)
    }
}

/// Where to get TeX: the start window's notice and the PDF pane link here.
let macTeXURL = URL(string: "https://tug.org/mactex/")!

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

/// A template's card: a drawing of its first page, then its name.
private struct TemplateCard: View {
    let template: ProjectTemplate
    /// A drawing of a Letter page: the thumbnail's size and its corners.
    private static let page = CGSize(width: 120, height: 156)
    private static let corner: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading) {
            PagePreview(page: template.page)
                .frame(width: Self.page.width, height: Self.page.height)
                .background(.white, in: .rect(cornerRadius: Self.corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(.separator)
                }
            VStack(alignment: .leading) {
                Text(template.title).font(.headline)
                Text(template.detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: Self.page.width, alignment: .leading)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Grey bars where the text would be, laid out like the template's first
/// page (or first slide).
private struct PagePreview: View {
    let page: ProjectTemplate.Page

    var body: some View {
        switch page {
        case .blank:
            Image(systemName: "plus")
                .font(.largeTitle)
                .fontWeight(.light)
                .foregroundStyle(.gray.opacity(0.6))
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
                    Rectangle().fill(.blue.opacity(0.55)).frame(height: 14)
                    bar(60, 4)
                    bar(40, 3)
                    Spacer()
                }
                .frame(width: 104, height: 58)
                .background(.white)
                .overlay(Rectangle().strokeBorder(.gray.opacity(0.3)))
                Spacer()
            }
        }
    }

    private var heading: some View {
        HStack { bar(40, 3); Spacer() }.padding(.horizontal, 16)
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        Capsule().fill(.gray.opacity(0.45)).frame(width: width, height: height)
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = "article"

    var body: some View {
        // A sheet shows no navigation title, so the form's header names it.
        // The template arrives chosen (from a card, or "article" for ⌘N);
        // the menu is there to change it.
        Form {
            Section("New Project") {
                TextField("Name", text: $name, prompt: Text("My Paper"))
                Picker("Template", selection: $template) {
                    ForEach(ProjectTemplate.all) { Text($0.title).tag($0.id) }
                }
            }
        }
        .onAppear { template = app.newProjectTemplate }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    let name = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await app.create(name: name, template: template) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
