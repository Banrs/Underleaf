import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var currentProjectId: String?
    @Published var tree: [FileNode] = []
    @Published var openPath: String?
    @Published var outline: [OutlineItem] = []
    @Published var dirty = false
    @Published var compiling = false
    @Published var lastResult: CompileResult?
    @Published var texAvailable = false
    @Published var isDark = false

    let editor = EditorController()
    private var root: URL?
    private var projectGeneration = 0

    init() {
        editor.model = self
        refreshProjects()
        Task.detached { let t = Compiler.texAvailable(); await MainActor.run { self.texAvailable = t.available } }
    }

    func webViewReady() {
        editor.setDark(isDark)
        if let p = openPath { openFile(p) } // re-open after a reload
    }

    // MARK: projects / tree

    func refreshProjects() { projects = ProjectStore.listProjects() }

    func openProject(_ id: String) {
        guard let r = try? ProjectStore.projectRoot(id) else { return }
        projectGeneration += 1
        root = r
        currentProjectId = id
        compiling = false
        lastResult = nil
        tree = ProjectStore.fileTree(r)
        openFile(ProjectStore.readSettings(r).mainFile)
    }

    func refreshTree() { if let r = root { tree = ProjectStore.fileTree(r) } }

    // MARK: files

    func openFile(_ path: String) {
        guard let r = root else { return }
        guard let content = try? ProjectStore.readFile(r, path) else { return }
        openPath = path
        outline = OutlineParser.parse(path.hasSuffix(".tex") ? content : "")
        editor.open(path: path, content: content, dark: isDark)
        dirty = false
    }

    func saveFile(path: String, content: String) {
        guard let r = root else { return }
        try? ProjectStore.writeFile(r, path, content)
        if path == openPath {
            dirty = false
            if path.hasSuffix(".tex") { outline = OutlineParser.parse(content) }
        }
    }

    // MARK: compile

    func compile() {
        guard let r = root, let id = currentProjectId, texAvailable, !compiling else { return }
        let generation = projectGeneration
        compiling = true
        Task.detached {
            let result = try? Compiler.compile(r)
            await MainActor.run {
                guard generation == self.projectGeneration, id == self.currentProjectId else { return }
                self.compiling = false
                self.lastResult = result
                if result?.ok == true { self.editor.reloadPDF(projectId: id) }
            }
        }
    }

    // MARK: synctex (inverse: PDF click → source)

    func inverseSync(page: Int, x: Double, y: Double) {
        guard let r = root else { return }
        let generation = projectGeneration
        Task.detached {
            guard let hit = try? Compiler.synctexInverse(r, page: page, x: x, y: y) else { return }
            await MainActor.run {
                guard generation == self.projectGeneration else { return }
                self.openFile(hit.file)
                self.editor.gotoLine(hit.line)
            }
        }
    }

    // MARK: theme
    func applyDark(_ dark: Bool) { isDark = dark; editor.setDark(dark) }
}

struct OutlineItem: Identifiable, Hashable { let id = UUID(); var depth: Int; var title: String; var line: Int }

enum OutlineParser {
    private static let re = try! NSRegularExpression(pattern: #"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)
    private static let depth = ["part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5]
    static func parse(_ text: String) -> [OutlineItem] {
        var out: [OutlineItem] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("%") { continue }
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let kind = ns.substring(with: m.range(at: 1))
                out.append(OutlineItem(depth: depth[kind] ?? 2, title: ns.substring(with: m.range(at: 2)), line: i + 1))
            }
        }
        return out
    }
}
