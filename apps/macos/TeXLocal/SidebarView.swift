import SwiftUI

/// Files, project search and the document outline, in the source-list style.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var selection: String?
    @State private var deleting: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        List(selection: $selection) {
            if project.searchQuery.isEmpty {
                Section("Files") {
                    OutlineGroup(project.tree, children: \.children) { node in
                        row(node).tag(node.path)
                    }
                }
                if !project.outline.isEmpty {
                    Section("Outline") {
                        ForEach(project.outline) { item in
                            Button {
                                project.reveal(line: item.line)
                            } label: {
                                Text(item.title)
                                    .lineLimit(1)
                                    .padding(.leading, CGFloat(max(0, item.level - 2)) * 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Section("\(project.searchHits.count) Results") {
                    ForEach(project.searchHits) { hit in
                        Button {
                            Task { await project.open(hit.file, line: hit.line) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(hit.file):\(hit.line)").font(.caption).foregroundStyle(.secondary)
                                (Text(hit.before) + Text(hit.match).bold().foregroundStyle(.tint) + Text(hit.after))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $project.searchQuery, placement: .sidebar, prompt: "Search Project")
        .searchFocused($searchFocused)
        .onChange(of: app.searchFocusToken) { _, _ in searchFocused = true }
        .onChange(of: selection) { _, path in
            if let path, isTextFile(path) { Task { await project.open(path) } }
        }
        .onChange(of: project.openPath) { _, path in selection = path }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await project.importFiles(urls) }
            return true
        }
        .toolbar {
            ToolbarItem {
                Menu("Add", systemImage: "plus") {
                    Button(MenuCommand.fileNew.title) { app.perform(.fileNew) }
                    Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder) }
                    Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(project.settings?.engine ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .confirmationDialog(
            "Move “\(deleting ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let path = deleting { Task { await project.deleteEntry(path) } }
            }
        }
    }

    private func row(_ node: TreeNode) -> some View {
        Label {
            HStack {
                Text(node.name)
                if node.path == project.settings?.mainFile {
                    Spacer()
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .imageScale(.small)
                        .help("Main file")
                }
            }
        } icon: {
            Image(systemName: icon(for: node))
        }
        .contextMenu {
            if !node.isDirectory && node.path.hasSuffix(".tex") {
                Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
                Divider()
            }
            Button("Rename…") { app.prompt = .renameEntry(node.path) }
            Button("Show in Finder") { reveal(node) }
            Divider()
            Button("Move to Trash", role: .destructive) { deleting = node.path }
        }
    }

    private func icon(for node: TreeNode) -> String {
        if node.isDirectory { return "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "tex": return "doc.text"
        case "bib": return "books.vertical"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private func reveal(_ node: TreeNode) {
        Task {
            if let abs = try? await Core.shared.call("raw_path", ["id": project.id, "path": node.path], as: String.self) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
            }
        }
    }
}
