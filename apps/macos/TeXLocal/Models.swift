import Foundation

// The core's JSON shapes (crates/texlocal-core). Field names match its
// camelCase serialization.

struct ProjectInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Milliseconds since 1970.
    let mtime: Double
    let mainFile: String

    var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}

struct TreeNode: Decodable, Identifiable, Hashable {
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
}

struct ProjectSettings: Decodable {
    let mainFile: String
    let engine: String
    let shellEscape: Bool
}

struct LogItem: Decodable, Hashable {
    let type: String
    let file: String?
    let line: Int?
    let message: String

    var isError: Bool { type == "error" }
}

struct CompileResult: Decodable {
    let ok: Bool
    let durationMs: Int
    let pdf: String?
    let errors: [LogItem]
    let warnings: [LogItem]
    let log: String
}

extension CompileResult {
    /// How long the build took, as every place that shows it reads it: "1.2 s".
    var durationText: String {
        "\((Double(durationMs) / 1000).formatted(.number.precision(.fractionLength(1)))) s"
    }
}

struct Symbols: Decodable {
    let citations: [String]
    let labels: [String]
}

struct SearchHit: Decodable, Hashable, Identifiable {
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
struct ForwardLoc: Decodable, Equatable {
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

struct Saved: Decodable {
    let saved: [String]
}

/// `rename_entry`'s result: both paths normalised, and the main file, which
/// moves when it or its folder does.
struct RenameResult: Decodable {
    let from: String
    let to: String
    let mainFile: String
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
let textExtensions: Set<String> = [
    "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
    "py", "r", "dat", "def", "clo", "tikz", "svg",
]

func isTextFile(_ path: String) -> Bool {
    textExtensions.contains((path as NSString).pathExtension.lowercased())
}
