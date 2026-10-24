import SwiftUI
import UniformTypeIdentifiers

/// Templates over every project in the library, as the Mac's Home; a tap opens, a long press or a swipe offers the rest.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var rename = InPlaceRename<ProjectInfo.ID>()

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Group { if let problem = app.libraryProblem { LibraryUnavailable(problem: problem) } else { list } }
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
        .refreshable { await app.refresh() }
    }

    private var list: some View {
        List {
            if query.isEmpty {
                Section("New") {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(ProjectTemplate.allCases) { template in
                                Button { app.newProject(template) } label: {
                                    TemplateCard(template: template).padding(6).contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                                .accessibilityHint("Starts a project from this template")
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
                    row(Text(url.lastPathComponent), detail: Text("Opening…"), progress: "Opening")
                }
                ForEach(shown) { project in
                    Group {
                        // Not in the button while it's edited, where a tap in the name would open the project.
                        if rename.id == project.id {
                            row(RenameField(text: $rename.name, ended: {}) { commitRename(project) } cancel: { rename.cancel() },
                                project: project)
                        } else {
                            Button { Task { await app.open(project.id) } } label: { row(Text(project.name), project: project) }
                                .foregroundStyle(.primary)
                        }
                    }
                    .contextMenu { actions(project) }
                    .swipeActions { swipe(project) }
                    .renameAction { rename.begin(project.id, name: project.name) }
                }
                if app.projectsLoaded, shown.isEmpty { NoProjects(query: query) }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// A long press's, the destructive one last as the sidebar's; an opened folder isn't the library's to rename or delete.
    @ViewBuilder private func actions(_ project: ProjectInfo) -> some View {
        if !project.opened {
            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await app.duplicate(project) } }
            RenameButton()
        }
        remove(project)
    }

    /// A swipe's, the full swipe's first.
    @ViewBuilder private func swipe(_ project: ProjectInfo) -> some View {
        remove(project)
        if !project.opened { RenameButton() }
    }

    @ViewBuilder private func remove(_ project: ProjectInfo) -> some View {
        if project.opened {
            Button("Remove from List", systemImage: "minus.circle", role: .destructive) { Task { await app.forget(project) } }
        } else {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await app.delete(project) } }
        }
    }

    private func row(_ name: some View, project: ProjectInfo) -> some View {
        row(name, detail: detail(project), symbol: project.opened ? "folder" : "text.document", dimmed: project.missing,
            progress: project.id == app.opening ? "Opening" : nil)
    }

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await app.rename(project, to: name) }
    }

    /// A touch's 44 pt, the whole row.
    private func row(_ name: some View, detail: Text, symbol: String = "text.document", dimmed: Bool = false,
                     progress: String?) -> some View {
        ProjectLabel(detail: detail, symbol: symbol, dimmed: dimmed, progress: progress) { name.font(.headline) }
            .frame(minHeight: 44)
            .contentShape(.rect)
    }

    private func detail(_ project: ProjectInfo) -> Text {
        guard project.opened else { return Text("\(Text(project.mainFile)) · \(Text(project.modified, format: .relative(presentation: .named)))") }
        return project.missing ? Text("\(project.folder.lastPathComponent) · Not Found") : Text(project.folder.lastPathComponent)
    }

    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
