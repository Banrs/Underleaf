import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @FocusState private var listFocused: Bool
    @FocusState private var searching: Bool
    @State private var query = ""
    @AppStorage(DefaultsKey.dismissedTeXTip) private var dismissedTeXTip = false
    /// What was still at work 300 ms after it began: a quick open or copy shows no spinner.
    @State private var slowOpening: String?
    @State private var slowImports: [URL] = []

    var body: some View {
        Group { if let problem = app.libraryProblem { unavailable(problem) } else { list } }
        .safeAreaBar(edge: .top) { if app.tex?.available == false, !dismissedTeXTip { texMissing } }
        .fileDrop(accepts: { app.libraryProblem == nil && AppModel.canOpen($0) }) { urls in Task { await app.importProjects(urls) } }
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
            // No section header: the list pins its first one with a rule the full width of the window.
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
                ForEach(copying, id: \.self) { url in
                    ProjectLabel(detail: Text("Copying…"), progress: "Copying") { Text(url.lastPathComponent).font(.headline) }
                }
                ForEach(shown) { project in
                    // Its own view, so a row redraws only when its rename starts or ends.
                    ProjectRow(project: project, working: project.id == app.opening && (project.id == slowOpening || copied),
                               rename: rename, ended: { listFocused = true }) { commitRename(project) }
                }
                if app.projectsLoaded, shown.isEmpty { empty.frame(maxWidth: .infinity).selectionDisabled() }
            } header: { Text("All Projects") }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
            if let project = app.projects.first(where: { ids.contains($0.id) }) {
                Button("Open") { Task { await app.open(project.id) } }
                Divider()
                ItemMenuItems(actions: actions(project))
            }
        } primaryAction: { ids in if let id = ids.first { Task { await app.open(id) } } }
        .onKeyPress(.return) {
            guard rename.id == nil, let id = selection else { return .ignored }
            Task { await app.open(id) }
            return .handled
        }
        .focused($listFocused)
        .offersActions(for: listFocused && rename.id == nil ? selection : nil) { id in shown.first { $0.id == id }.map(actions) }
    }

    private func actions(_ project: ProjectInfo) -> ItemActions {
        ItemActions(rename: { rename.begin(project.id, name: project.name) },
                    showInFinder: { app.revealProject(project) },
                    moveToTrash: { Task { await app.delete(project) } })
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

    private var copying: [URL] { query.isEmpty ? slowImports.filter(app.importing.contains) : [] }

    /// A copy shown has ended: the project opening is its own, at work in its own row from then on.
    private var copied: Bool { slowImports.contains { !app.importing.contains($0) } }

    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var texMissing: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("MacTeX isn’t installed. Install it to compile; TeXLocal finds it afterwards.",
                  systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            Spacer()
            OpenLinkButton.getMacTeX
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
    let ended, commit: () -> Void

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

/// A button that opens a page in the browser.
struct OpenLinkButton: View {
    static var getMacTeX: Self { Self(title: "Get MacTeX", url: Links.mactex) }
    static var texpressoGuide: Self { Self(title: "Install Guide", url: Links.texpressoGuide) }
    let title: LocalizedStringKey
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View { Button(title) { openURL(url) } }
}

enum ProjectTemplate: String, CaseIterable, Identifiable {
    case blank, article, report, beamer

    static let standard = ProjectTemplate.article

    var id: String { rawValue }

    var title: String { self == .beamer ? "Presentation" : rawValue.capitalized }
}

/// An image button (HIG, Buttons): no border at rest, 10 pt from the content to the clickable edge,
/// and a fill under the pointer that deepens while pressed.
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

/// A template's card: a drawing of its first page with its name under it, as in a template chooser.
private struct TemplateCard: View {
    let template: ProjectTemplate
    /// A US Letter page, 120 pt wide; its corner is drawn to look like paper, not to the kit.
    private static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    static let width = page.width + 2 * TemplateButtonStyle.edge
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 8) {
            PagePreview(template: template)
                .frame(width: Self.page.width, height: Self.page.height)
                // White paper in either appearance, dimmed a little in dark mode; the drawing in light colours, made for paper.
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1), in: paper)
                .overlay(paper.strokeBorder(.separator))
                .environment(\.colorScheme, .light)
                // The card reads as its name ("Blank", not "Add, Blank").
                .accessibilityHidden(true)
            Text(template.title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Bars where the text would be, laid out like the template's first page, in points of the 120 pt page.
private struct PagePreview: View {
    let template: ProjectTemplate

    var body: some View {
        switch template {
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
        case .beamer:
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    Rectangle().fill(.tint.secondary).frame(height: 14)
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

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View { Capsule().fill(.tertiary).frame(width: width, height: height) }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @State private var name: String
    @State private var template: ProjectTemplate
    @FocusState private var nameFocused: Bool

    init(draft: NewProjectDraft) {
        _template = State(initialValue: draft.template)
        _name = State(initialValue: draft.name)
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
            Picker("Template", selection: $template) { ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) } }
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

#Preview("Template cards") {
    HStack(alignment: .top) { ForEach(ProjectTemplate.allCases) { TemplateCard(template: $0) } }
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
