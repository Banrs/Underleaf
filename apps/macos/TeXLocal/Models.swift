import Foundation

// The core's JSON shapes (crates/texlocal-core). Field names match its
// camelCase serialization.

struct ProjectInfo: Decodable, Identifiable {
    let id: String
    let name: String
    /// Milliseconds since 1970.
    let mtime: Double
    let mainFile: String

    var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}

struct TreeNode: Decodable, Identifiable {
    let type: String
    let name: String
    let path: String
    let children: [TreeNode]?

    var id: String { path }
    var isDirectory: Bool { type == "dir" }
}

struct TexStatus: Decodable {
    let available: Bool
    let version: String?
    /// The folder latexmk runs from.
    var found: String?

    /// The distribution latexmk belongs to, from the folder it runs from
    /// with links followed (/Library/TeX/texbin is MacTeX's link into
    /// /usr/local/texlive/2026/bin/…): "TeX Live 2026", "MiKTeX", or nil.
    var distribution: String? {
        guard let found else { return nil }
        let path = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        if let match = path.firstMatch(of: /texlive\/(\d{4})\//) { return "TeX Live \(match.1)" }
        if path.localizedCaseInsensitiveContains("miktex") { return "MiKTeX" }
        return nil
    }
}

struct ProjectSettings: Decodable {
    let mainFile: String
    let engine: String
    let shellEscape: Bool
}

struct LogItem: Decodable {
    let type: String
    let file: String?
    let line: Int?
    let message: String

    var isError: Bool { type == "error" }
}

struct CompileResult: Decodable {
    let ok: Bool
    let durationMs: Int
    let errors: [LogItem]
    let warnings: [LogItem]
    let log: String

    /// How long the build took, as every place that shows it reads it: "1.2 s".
    var durationText: String {
        "\((Double(durationMs) / 1000).formatted(.number.precision(.fractionLength(1)))) s"
    }
}

struct Symbols: Decodable {
    let citations: [String]
    let labels: [String]
}

struct SearchHit: Decodable, Identifiable {
    let file: String
    let line: Int
    let before: String
    let match: String
    let after: String

    var id: String { "\(file):\(line):\(before.count)" }
}

struct FileText: Decodable {
    let text: String
}

/// A SyncTeX box in PDF points, origin at the page's top-left: the baseline
/// point (h, v) and the box's width and height above it.
struct ForwardLoc: Decodable {
    let page: Double
    let h: Double?
    let v: Double?
    let width: Double?
    let height: Double?
}

struct InverseLoc: Decodable {
    let file: String
    let line: Int
}

/// `rename_entry`'s result: both paths normalised.
struct RenameResult: Decodable {
    let from: String
    let to: String
}

/// Where a path is after `from` moved to `to`: the entry itself, or anything
/// inside it when it is a folder (web/src/sidebar.js `remapPath`).
func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}

/// The extensions the core treats as text (projects.rs `TEXT_EXT`); anything
/// else opens in its own app rather than the editor.
func isTextFile(_ path: String) -> Bool {
    [
        "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
        "py", "r", "dat", "def", "clo", "tikz", "svg",
    ].contains((path as NSString).pathExtension.lowercased())
}
