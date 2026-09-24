import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ProjectInfo.ID?
    @State private var renaming: ProjectInfo?
    @State private var newName = ""
    @State private var deleting: ProjectInfo?

    var body: some View {
        HStack(spacing: 0) {
            brand
                .frame(width: 320)
                .padding(32)
            Divider()
            projectList
        }
        .navigationTitle("TeXLocal")
        .toolbar {
            ToolbarItem {
                Button("New Project", systemImage: "plus") { app.showNewProject = true }
            }
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

    private var brand: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("TeXLocal").font(.largeTitle.bold())
            Text("Offline LaTeX editing and compilation.\nYour files never leave this machine.")
                .foregroundStyle(.secondary)
            if app.tex?.available == false {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TeX isn’t installed").bold()
                        Text("Install MacTeX to compile documents. TeXLocal notices it once installed.")
                        Link("Get MacTeX", destination: URL(string: "https://tug.org/mactex/")!)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
            }
            Button {
                app.showNewProject = true
            } label: {
                Label("New Project", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var projectList: some View {
        List(app.projects, selection: $selection) { project in
            HStack {
                Image(systemName: "doc.text").foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(project.name)
                    Text(project.modified, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
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
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "doc.text",
                    description: Text("Create a project to start writing.")
                )
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
