import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ProjectInfo.ID?
    @State private var renaming: ProjectInfo?
    @State private var newName = ""
    @State private var deleting: ProjectInfo?

    var body: some View {
        projectList
        // Named for what the window shows, not the app (HIG, Toolbars).
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Project", systemImage: "plus") { app.showNewProject = true }
                    .help("New Project (⌘N)")
            }
        }
        .safeAreaBar(edge: .top) {
            if app.tex?.available == false { texMissing }
        }
        .task(id: app.tex?.available) { await app.watchForTeX() }
        .alert("Rename Project", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let project = renaming { Task { await app.rename(project, to: newName) } }
            }
        }
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let project = deleting { Task { await app.delete(project) } }
            }
        } message: {
            Text("You can restore it from the Trash.")
        }
    }

    private var texMissing: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text("TeX isn’t installed. Install MacTeX to compile; TeXLocal notices it once it’s there.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Link("Get MacTeX", destination: URL(string: "https://tug.org/mactex/")!)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var projectList: some View {
        List(app.projects, selection: $selection) { project in
            Label {
                VStack(alignment: .leading) {
                    Text(project.name)
                    Text(project.modified, format: .relative(presentation: .named))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
            if let project = app.projects.first(where: { ids.contains($0.id) }) {
                Button("Open") { Task { await app.open(project.id) } }
                Button("Rename…") { newName = project.name; renaming = project }
                Divider()
                Button("Move to Trash", role: .destructive) { deleting = project }
            }
        } primaryAction: { ids in
            if let id = ids.first { Task { await app.open(id) } }
        }
        .overlay {
            if app.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "doc.text")
                } description: {
                    Text("Create a project to start writing. Your files never leave this Mac.")
                } actions: {
                    Button("New Project") { app.showNewProject = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = "article"

    private let templates = [
        ("article", "Article"), ("report", "Report"), ("beamer", "Beamer Slides"), ("blank", "Blank"),
    ]

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("My Paper"))
            Picker("Template", selection: $template) {
                ForEach(templates, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.radioGroup)
        }
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
        .navigationTitle("New Project")
    }
}
