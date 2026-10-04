import Foundation

// The Rust core's JSON shapes use camelCase keys.

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

/// A project path's parts.
nonisolated extension String {
    /// "" at the project's top level.
    var parentFolder: String { (self as NSString).deletingLastPathComponent }
    var fileName: String { (self as NSString).lastPathComponent }

    /// A name numbered as Finder numbers another of it, before its extension:
    /// "untitled 2.tex", "untitled folder 2" (the core's `numbered`).
    func numbered(_ number: Int) -> String {
        guard let dot = lastIndex(of: "."), dot > startIndex else { return "\(self) \(number)" }
        return "\(self[..<dot]) \(number)\(self[dot...])"
    }
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
    /// True when this run wrote the advertised PDF, even if TeX reported errors.
    let pdfChanged: Bool
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
    /// Every matching line box, in page order; absent when the box above is the only one.
    var matches: [ForwardLoc]? = nil
}

nonisolated struct InverseLoc: Decodable {
    let file: String
    let line: Int
    /// The clicked letter's, in UTF-16 units.
    let column: Int?
}

/// `import_files`' result: the incoming paths that already exist here.
/// Asked nothing about them, it writes nothing.
nonisolated struct Imported: Decodable {
    nonisolated struct Clash: Decodable {
        let path: String
    }

    let existing: [Clash]
}

/// `rename_entry`'s normalized paths and main file.
nonisolated struct RenameResult: Decodable {
    let from: String
    let to: String
    let mainFile: String
}

/// Remaps an entry and its descendants when a folder moves.
func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}

/// A file's kind by its extension, so each list of extensions is written once.
private nonisolated enum FileKind {
    case text
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

/// A Move to Trash that Edit › Undo takes back, as Finder's does. The move goes through
/// `FileManager`, which says where the Trash put the item (the core's trash doesn't). Undo
/// puts it back and Redo trashes it again; each registers the other as its handler starts,
/// so a stack's other entries survive the work that follows. The handlers hold the item:
/// an undo manager doesn't retain its targets.
@MainActor
final class UndoableTrash {
    let original: URL
    let name: String
    /// Where the Trash put it.
    private var trashed: URL?
    private weak var undoManager: UndoManager?
    /// Does the move, calling `recycle` where it belongs; false once it has failed and said so.
    private let trash: (UndoableTrash) async -> Bool
    /// Runs once the item is back or gone again, for whatever lists it.
    private let changed: () async -> Void
    private let failed: (String, Error) -> Void

    init(original: URL, name: String, undoManager: UndoManager?,
         trash: @escaping (UndoableTrash) async -> Bool,
         changed: @escaping () async -> Void,
         failed: @escaping (String, Error) -> Void) {
        self.original = original
        self.name = name
        self.undoManager = undoManager
        self.trash = trash
        self.changed = changed
        self.failed = failed
    }

    /// The move itself, for `trash` to call. An item already gone is left.
    func recycle() throws {
        guard FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) else { return }
        var result: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &result)
        trashed = result as URL?
    }

    /// The user's own Move to Trash.
    func moveToTrash() async {
        if await trash(self) { registerPutBack() }
    }

    private func registerPutBack() {
        undoManager?.registerUndo(withTarget: self) { _ in self.putBack() }
        undoManager?.setActionName(String(localized: "Move to Trash"))
    }

    private func registerTrashAgain() {
        undoManager?.registerUndo(withTarget: self) { _ in self.trashAgain() }
        undoManager?.setActionName(String(localized: "Move to Trash"))
    }

    private func putBack() {
        guard let trashed else { return }
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: original)
        } catch {
            failed("Couldn’t Put “\(name)” Back", error)
            return
        }
        self.trashed = nil
        registerTrashAgain()
        Task { await changed() }
    }

    private func trashAgain() {
        registerPutBack()
        Task {
            if await trash(self) { await changed() } else { undoManager?.removeAllActions(withTarget: self) }
        }
    }
}

func isTextFile(_ path: String) -> Bool {
    FileKind(path) == .text
}

/// LaTeX's own tools (the outline, Set as Main File) for `.tex`, in any case, as the core reads it.
func isLaTeXFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "tex"
}

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
