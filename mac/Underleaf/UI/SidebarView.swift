import SwiftUI

// Native source list. `List(.sidebar)` + `OutlineGroup` give the exact macOS tree
// spacing, disclosure triangles, tinted icons, translucent selection ("liquid
// glass") and vibrancy automatically — none of it is hand-tuned. That's the whole
// reason for the native shell.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    // Selection is derived from the model, so programmatic opens (project
    // switch, inverse SyncTeX) highlight the right row and re-clicking a row
    // after a switch still works.
    private var selection: Binding<String?> {
        Binding(
            get: { model.openPath },
            set: { if let p = $0, isFile(p) { model.openFile(p) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Files") {
                OutlineGroup(model.tree, children: \.children) { node in
                    Label(node.name, systemImage: icon(for: node))
                        .foregroundStyle(node.type == "dir" ? Color.accentColor : .primary, .secondary)
                        .tag(node.path)
                }
            }
            if !model.outline.isEmpty {
                Section("Outline") {
                    ForEach(model.outline) { item in
                        Text(item.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(item.depth) * 10)
                            .onTapGesture { model.editor.gotoLine(item.line) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { projectPicker }   // above the list, in the sidebar
    }

    private var projectPicker: some View {
        Picker("Project", selection: Binding(
            get: { model.currentProjectId ?? "" },
            set: { if !$0.isEmpty { model.openProject($0) } })) {
            ForEach(model.projects) { p in Text(p.name).tag(p.id) }
        }
        .labelsHidden()
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func isFile(_ path: String) -> Bool {
        func find(_ nodes: [FileNode]) -> Bool {
            for n in nodes {
                if n.path == path { return n.type == "file" }
                if let c = n.children, find(c) { return true }
            }
            return false
        }
        return find(model.tree)
    }

    private func icon(for node: FileNode) -> String {
        if node.type == "dir" { return "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "tex", "bbl": return "doc.text"
        case "bib": return "book"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp": return "photo"
        case "cls", "sty", "bst", "def", "clo": return "gearshape"
        default: return "doc"
        }
    }
}
