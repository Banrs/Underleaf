import Foundation

// Port of server/projects.js. Every project is a directory under DATA_DIR
// (~/TeXLocal — same as the Electron app, so existing projects carry over).
// Per-project settings live in <project>/.texlocal.json.
//
// Read-only surface: the native shell browses, opens and saves files; project
// and file management (create/rename/delete, search, symbols) still lives in
// the JS backend. Port those from server/projects.js when the UI needs them.

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}

// MARK: - Models

struct FileNode: Codable, Identifiable, Hashable {
    var type: String        // "file" | "dir"
    var name: String
    var path: String        // project-relative
    var children: [FileNode]?
    var id: String { path }
}

struct ProjectInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var mtime: Double
    var mainFile: String
}

struct Settings: Decodable, Hashable {
    var mainFile = "main.tex"
    var engine = "pdflatex"
    var shellEscape = false

    // decodeIfPresent per key: synthesized Decodable throws on any missing key,
    // which would silently reset a hand-edited partial .texlocal.json to ALL
    // defaults (the JS side merges over defaults instead).
    private enum CodingKeys: String, CodingKey { case mainFile, engine, shellEscape }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mainFile = try c.decodeIfPresent(String.self, forKey: .mainFile) ?? "main.tex"
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "pdflatex"
        shellEscape = try c.decodeIfPresent(Bool.self, forKey: .shellEscape) ?? false
    }
}

enum ProjectStore {
    static let buildDir = "build"
    private static let settingsFile = ".texlocal.json"
    private static let fm = FileManager.default

    static let dataDir: URL = {
        // TEXLOCAL_DATA override (matches the Node backend), else ~/TeXLocal.
        // Resolved against the cwd because a GUI-launched app's cwd is "/".
        let base: URL
        if let env = ProcessInfo.processInfo.environment["TEXLOCAL_DATA"] {
            base = URL(fileURLWithPath: env, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
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
    // The settings file is reserved (mirrors server/projects.js).
    static func safePath(_ root: URL, _ rel: String) throws -> URL {
        guard !rel.isEmpty else { throw BackendError("Missing path") }
        let abs = root.appendingPathComponent(rel).standardizedFileURL
        guard abs.path.hasPrefix(root.path + "/") else { throw BackendError("Path escapes project") }
        guard abs.path != root.path + "/" + settingsFile else { throw BackendError("Reserved file") }
        return abs
    }

    // A normalized project-relative file path that is safe to pass as a command
    // argument. In particular, no component may be interpreted as an option.
    static func safeRelativeFile(_ root: URL, _ rel: String) throws -> String {
        let abs = try safePath(root, rel)
        let normalized = String(abs.path.dropFirst(root.path.count + 1))
        guard !normalized.split(separator: "/").contains(where: { $0.hasPrefix("-") }) else {
            throw BackendError("Path segments cannot start with \"-\"")
        }
        return normalized
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

    // The compiled PDF path — the ONE place this is derived (mirrors compiledPdfPath).
    static func compiledPdfPath(_ root: URL) -> URL {
        let main = readSettings(root).mainFile
        let base = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
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

    // MARK: files

    static func fileTree(_ root: URL, _ dir: URL? = nil) -> [FileNode] {
        let dir = dir ?? root
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var nodes: [FileNode] = []
        for e in entries {
            let name = e.lastPathComponent
            if name.hasPrefix(".") { continue }
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
}
