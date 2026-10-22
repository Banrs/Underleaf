import SwiftUI
import UniformTypeIdentifiers

/// Templates over every project in the library, as the Mac's Home; a tap opens, a long press or a swipe offers the rest.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var renaming: ProjectInfo?
    @State private var newName = ""

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Group { if let problem = app.libraryProblem { unavailable(problem) } else { list } }
                .navigationTitle("Projects")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Open", systemImage: "folder") { app.openingProject = true }
                        Button("New Project", systemImage: "plus") { app.newProject() }
                    }
                }
                .disabled(app.libraryProblem != nil)
                .searchable(text: $query, prompt: "Search Projects")
        }
        .fileImporter(isPresented: $app.openingProject, allowedContentTypes: AppModel.openableTypes, allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { await app.open(urls) } }
        }
        .sheet(item: $app.newProjectDraft) { NewProjectSheet(draft: $0) }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { project in
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, name != project.name { Task { await app.rename(project, to: name) } }
            }
        }
        .refreshable { await app.refresh() }
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
        List {
            if query.isEmpty {
                Section("New") {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(ProjectTemplate.allCases) { template in
                                Button { app.newProject(template) } label: { TemplateCard(template: template) }
                                    .buttonStyle(.plain)
                                    .hoverEffect(.highlight)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }
            Section("All Projects") {
                ForEach(app.importing, id: \.self) { url in
                    ProjectRow(name: url.lastPathComponent, detail: Text("Opening…"), working: true)
                }
                ForEach(shown) { project in
                    Button { Task { await app.open(project.id) } } label: {
                        ProjectRow(name: project.name, detail: detail(project), symbol: project.opened ? "folder" : "text.document",
                                   dimmed: project.missing, working: project.id == app.opening)
                    }
                    .foregroundStyle(.primary)
                    .contextMenu { actions(project) }
                    .swipeActions { actions(project) }
                }
                if app.projectsLoaded, shown.isEmpty { empty }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// The same few for a long press and a swipe; an opened folder isn't the library's to rename or delete.
    @ViewBuilder private func actions(_ project: ProjectInfo) -> some View {
        if project.opened {
            Button("Remove from List", systemImage: "minus.circle", role: .destructive) { Task { await app.forget(project) } }
        } else {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await app.delete(project) } }
            Button("Rename", systemImage: "pencil") {
                newName = project.name
                renaming = project
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "text.document")
            } description: {
                Text("Choose a template above, or open a folder, .tex file or .zip from Files.")
            } actions: {
                Button("Open…") { app.openingProject = true }
            }
        }
    }

    private func detail(_ project: ProjectInfo) -> Text {
        guard project.opened else { return Text("\(Text(project.mainFile)) · \(Text(project.modified, format: .relative(presentation: .named)))") }
        return project.missing ? Text("\(project.folder.lastPathComponent) · Not Found") : Text(project.folder.lastPathComponent)
    }

    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct ProjectRow: View {
    let name: String
    let detail: Text
    var symbol = "text.document"
    var dimmed = false
    var working = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).foregroundStyle(dimmed ? .tertiary : .primary)
                    detail.font(.subheadline).foregroundStyle(dimmed ? .tertiary : .secondary).lineLimit(1).truncationMode(.middle)
                }
            } icon: {
                Image(systemName: symbol).font(.title2).foregroundStyle(dimmed ? .tertiary : .secondary)
            }
            if working {
                Spacer()
                ProgressView().accessibilityLabel("Opening")
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// A drawing of the template's first page with its name under it, as the Mac's card.
private struct TemplateCard: View {
    let template: ProjectTemplate
    private static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(spacing: 8) {
            PagePreview(template: template)
                .frame(width: Self.page.width, height: Self.page.height)
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1), in: paper)
                .overlay { paper.strokeBorder(.separator) }
                .environment(\.colorScheme, .light)
                .accessibilityHidden(true)
            Text(template.title).font(.subheadline)
        }
        .padding(6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Starts a project from this template")
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var draft: NewProjectDraft
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private var trimmed: String { draft.name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(create)
                Picker("Template", selection: $draft.template) { ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) } }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(trimmed.isEmpty || creating)
                }
            }
        }
        .defaultFocus($nameFocused, true)
    }

    private func create() {
        guard !trimmed.isEmpty, !creating else { return }
        creating = true
        Task {
            if await app.alerting("Couldn’t Create “\(trimmed)”", { try await app.create(name: trimmed, template: draft.template) }) != nil {
                dismiss()
            }
            creating = false
        }
    }
}
