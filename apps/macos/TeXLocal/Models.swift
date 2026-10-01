import Foundation

// The core's JSON shapes (crates/texlocal-core). Field names match its
// camelCase serialization.

nonisolated struct ProjectInfo: Decodable, Identifiable {
    let id: String
    let name: String
    /// Milliseconds since 1970.
    let mtime: Double
    let mainFile: String

    var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}

nonisolated struct TreeNode: Decodable, Identifiable, Equatable {
    let type: String
    let name: String
    let path: String
    let children: [TreeNode]?

    var id: String { path }
    var isDirectory: Bool { type == "dir" }
}

extension [TreeNode] {
    /// Every entry, each folder before what it holds.
    var flattened: [TreeNode] { flatMap { [$0] + ($0.children ?? []).flattened } }
}

nonisolated struct TexStatus: Decodable {
    let available: Bool
    /// The TeX folder chosen in Settings; nil finds TeX automatically.
    var texDir: String?
    /// The folder latexmk runs from.
    var found: String?
}

nonisolated struct ProjectSettings: Decodable {
    let mainFile: String
    let engine: String
    let shellEscape: Bool
    let stopOnFirstError: Bool
}

nonisolated struct LogItem: Decodable, Equatable {
    let type: String
    let file: String?
    let line: Int?
    let message: String

    var isError: Bool { type == "error" }
}

/// A build's outcome. Builds run past errors, so a failed one may still have
/// written a PDF; `stopped` means Stop, a newer build or quitting ended it.
nonisolated struct CompileResult: Decodable {
    let ok: Bool
    let stopped: Bool
    let pdf: String?
    let durationMs: Int
    let errors: [LogItem]
    let warnings: [LogItem]
    let log: String

    /// Ended on its own without a clean run, as opposed to stopped.
    var failed: Bool { !ok && !stopped }

    /// "1.2 s", in the user's locale.
    var durationText: String {
        Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

nonisolated struct Symbols: Decodable {
    let citations: [String]
    let labels: [String]
}

nonisolated struct SearchHit: Decodable, Identifiable {
    let file: String
    let line: Int
    let before: String
    let match: String
    let after: String

    var id: String { "\(file):\(line):\(before.count)" }
}

nonisolated struct FileText: Decodable {
    let text: String
}

/// A SyncTeX box in PDF points, origin at the page's top-left: the baseline
/// point (h, v) and the box's width and height above it.
nonisolated struct ForwardLoc: Decodable {
    let page: Double
    let h: Double?
    let v: Double?
    let width: Double?
    let height: Double?
}

nonisolated struct InverseLoc: Decodable {
    let file: String
    let line: Int
}

/// `import_files`' result: the incoming paths that already exist here.
/// Asked nothing about them, it writes nothing.
nonisolated struct Imported: Decodable {
    nonisolated struct Clash: Decodable {
        let path: String
    }

    let existing: [Clash]
}

/// `rename_entry`'s result: both paths normalised.
nonisolated struct RenameResult: Decodable {
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

/// A file's kind by its extension, so each list of extensions is written once.
private nonisolated enum FileKind {
    /// Opens in the editor (web/src/state.js `TEXT_FILE`).
    case text
    /// Previewed in the source column (web/src/state.js `IMAGE_FILE`).
    case image
    case pdf
    case other

    init(_ path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
             "py", "r", "dat", "def", "clo", "tikz":
            self = .text
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp": self = .image
        case "pdf": self = .pdf
        default: self = .other
        }
    }
}

/// The files the editor opens.
func isTextFile(_ path: String) -> Bool {
    FileKind(path) == .text
}

/// LaTeX's own tools (the outline, Set as Main File) for `.tex`, in any case, as the core reads it.
func isLaTeXFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "tex"
}

/// The files previewed in the source column; any other non-text file shows
/// No Preview there.
func isPreviewFile(_ path: String) -> Bool {
    [.image, .pdf].contains(FileKind(path))
}

/// A file's symbol in the sidebar.
func fileSymbol(_ path: String, directory: Bool = false) -> String {
    if directory { return "folder" }
    switch (path as NSString).pathExtension.lowercased() {
    case "tex": return "text.document"
    case "bib": return "books.vertical"
    default: break
    }
    return switch FileKind(path) {
    case .image: "photo"
    case .pdf: "richtext.page"
    case .text, .other: "document"
    }
}
