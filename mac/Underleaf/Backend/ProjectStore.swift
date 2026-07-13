import Foundation

// Port of server/projects.js. Every project is a directory under DATA_DIR
// (~/TeXLocal — same as the Electron app, so existing projects carry over).
// Per-project settings live in <project>/.texlocal.json.

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}

// MARK: - Models (Codable so they can cross the JS bridge unchanged)

struct FileNode: Codable, Identifiable, Hashable {
    var type: String        // "file" | "dir"
    var name: String
    var path: String        // project-relative
    var children: [FileNode]?
    var id: String { path }
}

struct ProjectInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var mtime: Double
    var mainFile: String
}

struct Settings: Codable, Hashable {
    var mainFile: String = "main.tex"
    var engine: String = "pdflatex"
    var shellEscape: Bool = false
}

struct SearchHit: Codable { var file: String; var line: Int; var before, match, after: String }
struct Symbols: Codable { var citations: [String]; var labels: [String] }

enum ProjectStore {
    static let buildDir = "build"
    private static let settingsFile = ".texlocal.json"
    private static let hidden: Set<String> = [".texlocal.json"]
    private static let fm = FileManager.default

    static let dataDir: URL = {
        // TEXLOCAL_DATA override (matches the Node backend), else ~/TeXLocal.
        let base: URL
        if let env = ProcessInfo.processInfo.environment["TEXLOCAL_DATA"] {
            base = URL(fileURLWithPath: env)
        } else {
            base = fm.homeDirectoryForCurrentUser.appendingPathComponent("TeXLocal")
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: path safety

    static func projectRoot(_ id: String) throws -> URL {
        let root = dataDir.appendingPathComponent(id).standardizedFileURL
        guard root.path.hasPrefix(dataDir.path + "/") else { throw BackendError("Bad project id") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackendError("No such project: \(id)")
        }
        return root
    }

    // Resolve a user-supplied relative path inside a project, rejecting escapes.
    static func safePath(_ root: URL, _ rel: String) throws -> URL {
        guard !rel.isEmpty else { throw BackendError("Missing path") }
        let abs = root.appendingPathComponent(rel).standardizedFileURL
        guard abs.path == root.path || abs.path.hasPrefix(root.path + "/") else {
            throw BackendError("Path escapes project")
        }
        return abs
    }

    static func sanitizeName(_ name: String) throws -> String {
        let stripped = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        let clean = String(stripped.prefix(80))
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw BackendError("Invalid name") }
        return clean
    }

    // MARK: settings

    static func readSettings(_ root: URL) -> Settings {
        let url = root.appendingPathComponent(settingsFile)
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return s
    }

    @discardableResult
    static func writeSettings(_ root: URL, _ patch: [String: Any]) throws -> Settings {
        var s = readSettings(root)
        if let v = patch["mainFile"] as? String { s.mainFile = v }
        if let v = patch["engine"] as? String { s.engine = v }
        if let v = patch["shellEscape"] as? Bool { s.shellEscape = v }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: root.appendingPathComponent(settingsFile))
        return s
    }

    // The compiled PDF path — the ONE place this is derived (mirrors compiledPdfPath).
    static func compiledPdfPath(_ root: URL) -> URL {
        let main = readSettings(root).mainFile
        let base = (main as NSString).deletingPathExtension
        return root.appendingPathComponent(buildDir).appendingPathComponent(base + ".pdf")
    }

    // MARK: projects

    static func listProjects() -> [ProjectInfo] {
        guard let entries = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return [] }
        var out: [ProjectInfo] = []
        for e in entries {
            let name = e.lastPathComponent
            if name.hasPrefix(".") { continue }
            let vals = try? e.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard vals?.isDirectory == true else { continue }
            let mtime = (vals?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
            out.append(ProjectInfo(id: name, name: name, mtime: mtime, mainFile: readSettings(e).mainFile))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    @discardableResult
    static func createProject(_ name: String, template: String = "article") throws -> ProjectInfo {
        let clean = try sanitizeName(name)
        let root = dataDir.appendingPathComponent(clean)
        guard !fm.fileExists(atPath: root.path) else { throw BackendError("A project with that name already exists") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, content) in Templates.files(for: template) {
            let abs = try safePath(root, rel)
            try fm.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: abs, atomically: true, encoding: .utf8)
        }
        try writeSettings(root, [:])
        return ProjectInfo(id: clean, name: clean, mtime: Date().timeIntervalSince1970 * 1000, mainFile: "main.tex")
    }

    static func renameProject(_ id: String, to newName: String) throws {
        let root = try projectRoot(id)
        let clean = try sanitizeName(newName)
        let dest = dataDir.appendingPathComponent(clean)
        guard !fm.fileExists(atPath: dest.path) else { throw BackendError("A project with that name already exists") }
        try fm.moveItem(at: root, to: dest)
    }

    static func deleteProject(_ id: String) throws {
        try fm.removeItem(at: try projectRoot(id))
    }

    // MARK: files

    static func fileTree(_ root: URL, _ dir: URL? = nil) -> [FileNode] {
        let dir = dir ?? root
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var nodes: [FileNode] = []
        for e in entries {
            let name = e.lastPathComponent
            if hidden.contains(name) || name.hasPrefix(".") { continue }
            let rel = String(e.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if rel == buildDir { continue }
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                nodes.append(FileNode(type: "dir", name: name, path: rel, children: fileTree(root, e)))
            } else {
                nodes.append(FileNode(type: "file", name: name, path: rel, children: nil))
            }
        }
        return nodes.sorted { a, b in
            if a.type == b.type { return a.name.localizedCompare(b.name) == .orderedAscending }
            return a.type == "dir"
        }
    }

    static func readFile(_ root: URL, _ rel: String) throws -> String {
        try String(contentsOf: try safePath(root, rel), encoding: .utf8)
    }

    static func writeFile(_ root: URL, _ rel: String, _ text: String) throws {
        let abs = try safePath(root, rel)
        try fm.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: abs, atomically: true, encoding: .utf8)
    }

    static func createFile(_ root: URL, _ rel: String, dir: Bool = false) throws {
        let abs = try safePath(root, rel)
        guard !fm.fileExists(atPath: abs.path) else { throw BackendError("Already exists") }
        if dir { try fm.createDirectory(at: abs, withIntermediateDirectories: true) }
        else {
            try fm.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: abs, atomically: true, encoding: .utf8)
        }
    }

    static func renameEntry(_ root: URL, _ from: String, _ to: String) throws {
        let src = try safePath(root, from), dest = try safePath(root, to)
        guard fm.fileExists(atPath: src.path) else { throw BackendError("Not found") }
        guard !fm.fileExists(atPath: dest.path) else { throw BackendError("Destination already exists") }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dest)
    }

    static func deleteEntry(_ root: URL, _ rel: String) throws {
        let abs = try safePath(root, rel)
        guard abs.path != root.path else { throw BackendError("Cannot delete project root") }
        try fm.removeItem(at: abs)
    }

    // MARK: search / symbols  (ported; not yet surfaced in the UI)

    private static let textExt: Set<String> = ["tex","bib","cls","sty","bst","txt","md","csv","tsv","json","yaml","yml","lua","py","r","dat","def","clo","tikz","svg"]

    static func search(_ root: URL, _ query: String, limit: Int = 100) -> [SearchHit] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        func walk(_ dir: URL) {
            guard hits.count < limit, let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for e in entries {
                if hits.count >= limit { return }
                let name = e.lastPathComponent
                if name.hasPrefix(".") || name == buildDir { continue }
                if (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walk(e); continue }
                let rel = String(e.path.dropFirst(root.path.count + 1))
                guard textExt.contains((rel as NSString).pathExtension.lowercased()),
                      let content = try? String(contentsOf: e, encoding: .utf8) else { continue }
                for (i, line) in content.components(separatedBy: "\n").enumerated() where hits.count < limit {
                    guard let r = line.lowercased().range(of: q) else { continue }
                    let col = line.distance(from: line.startIndex, to: r.lowerBound)
                    let start = max(0, col - 24)
                    let s = line.index(line.startIndex, offsetBy: start)
                    let mEnd = line.index(r.lowerBound, offsetBy: q.count)
                    let aEnd = line.index(mEnd, offsetBy: min(60, line.distance(from: mEnd, to: line.endIndex)))
                    hits.append(SearchHit(
                        file: rel, line: i + 1,
                        before: ((start > 0 ? "…" : "") + line[s..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                        match: String(line[r.lowerBound..<mEnd]),
                        after: String(line[mEnd..<aEnd]).trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        walk(root)
        return hits
    }

    static func scanSymbols(_ root: URL) -> Symbols {
        var keys: [String] = [], labels: [String] = []
        func walk(_ dir: URL) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for e in entries {
                let name = e.lastPathComponent
                if name.hasPrefix(".") || name == buildDir { continue }
                if (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walk(e); continue }
                let ext = (name as NSString).pathExtension.lowercased()
                guard let src = try? String(contentsOf: e, encoding: .utf8) else { continue }
                if ext == "bib" {
                    for m in src.matches(of: /@\w+\s*\{\s*([^,\s]+)\s*,/) { keys.append(String(m.1)) }
                } else if ext == "tex" {
                    for m in src.matches(of: /\\label\{([^}]+)\}/) { labels.append(String(m.1)) }
                }
            }
        }
        walk(root)
        return Symbols(citations: Array(Set(keys)), labels: Array(Set(labels)))
    }
}
