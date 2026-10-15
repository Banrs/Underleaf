import Foundation

// The Rust core's JSON shapes use camelCase keys.

nonisolated struct ProjectInfo: Decodable, Identifiable {
    let id: String
    let name: String
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
    var flattened: [TreeNode] { flatMap { [$0] + ($0.children ?? []).flattened } }
}

nonisolated extension String {
    var parentFolder: String { (self as NSString).deletingLastPathComponent }
    var fileName: String { (self as NSString).lastPathComponent }

    func numbered(_ number: Int) -> String {
        guard let dot = lastIndex(of: "."), dot > startIndex else { return "\(self) \(number)" }
        return "\(self[..<dot]) \(number)\(self[dot...])"
    }
}

nonisolated struct TexStatus: Decodable {
    let available: Bool
    var version: String?
    var texDir: String?
    var found: String?
    var texpresso: String?
    var texpressoDir: String?
}

nonisolated struct ProjectSettings: Decodable {
    var mainFile: String
    var engine: String
    var shellEscape: Bool
    var stopOnFirstError: Bool

    mutating func apply(_ change: SettingsChange) {
        switch change {
        case .mainFile(let path): mainFile = path
        case .engine(let name): engine = name
        case .shellEscape(let on): shellEscape = on
        case .stopOnFirstError(let on): stopOnFirstError = on
        }
    }
}

nonisolated enum SettingsChange {
    case mainFile(String), engine(String), shellEscape(Bool), stopOnFirstError(Bool)

    var patch: [String: any Sendable] {
        switch self {
        case .mainFile(let path): ["mainFile": path]
        case .engine(let name): ["engine": name]
        case .shellEscape(let on): ["shellEscape": on]
        case .stopOnFirstError(let on): ["stopOnFirstError": on]
        }
    }
}

nonisolated struct LogItem: Decodable, Equatable {
    let type: String
    let file: String?
    let line: Int?
    let message: String

    var isError: Bool { type == "error" }
}

/// Builds run past errors, so a failed one may still have written a PDF; `stopped` means Stop, a newer build or quitting ended it.
nonisolated struct CompileResult: Decodable {
    let ok: Bool
    let stopped: Bool
    let pdf: String?
    let pdfChanged: Bool
    let durationMs: Int
    let errors: [LogItem]
    let warnings: [LogItem]
    let log: String

    var failed: Bool { !ok && !stopped }

    var durationText: String {
        Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

nonisolated struct SearchHit: Decodable, Identifiable {
    let file: String
    let line: Int
    let before: String
    let match: String
    let after: String

    var id: String { "\(file):\(line):\(before.count)" }
}

nonisolated struct SearchGroup: Identifiable {
    let file: String
    let hits: [SearchHit]

    var id: String { file }
}

nonisolated struct FileText: Decodable {
    let text: String
}

/// In PDF points, origin at the page's top-left: the baseline point (h, v) and the box's width and height above it.
nonisolated struct ForwardLoc: Decodable {
    let page: Double
    let h: Double?
    let v: Double?
    let width: Double?
    let height: Double?
    var matches: [ForwardLoc]? = nil
}

nonisolated struct InverseLoc: Decodable {
    let file: String
    let line: Int
    let column: Int?
}

/// Asked nothing about them, it writes nothing.
nonisolated struct Imported: Decodable {
    nonisolated struct Clash: Decodable {
        let path: String
    }

    let existing: [Clash]
}

nonisolated struct RenameResult: Decodable {
    let from: String
    let to: String
    let mainFile: String
}

func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}

func restart<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    slot?.cancel()
    let task = Task { await work() }
    slot = task
    return task
}

func restart(_ slot: inout Task<Void, Never>?, after delay: Duration, _ work: @escaping @MainActor () async -> Void) {
    slot?.cancel()
    slot = Task {
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { await work() }
    }
}

/// The move goes through `FileManager`, which says where the Trash put the item (the core's trash doesn't). Each of Undo and
/// Redo registers the other as its handler starts, so a stack's other entries survive the work that follows. The handlers
/// hold the item: an undo manager doesn't retain its targets.
final class UndoableTrash {
    let original: URL
    let name: String
    private var trashed: URL?
    private weak var undoManager: UndoManager?
    private let trash: (UndoableTrash) async -> Bool
    private let changed: () async -> Void
    private let failed: (String, any Error) -> Void

    init(original: URL, name: String, undoManager: UndoManager?,
         trash: @escaping (UndoableTrash) async -> Bool,
         changed: @escaping () async -> Void,
         failed: @escaping (String, any Error) -> Void) {
        self.original = original
        self.name = name
        self.undoManager = undoManager
        self.trash = trash
        self.changed = changed
        self.failed = failed
    }

    func recycle() throws {
        guard FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) else { return }
        var result: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &result)
        trashed = result as URL?
    }

    func moveToTrash() async {
        if await trash(self) { register(putBack) }
    }

    private func register(_ undo: @escaping () -> Void) {
        undoManager?.registerUndo(withTarget: self) { _ in undo() }
        undoManager?.setActionName(String(localized: "Move to Trash"))
    }

    /// One asked while the last is still moving the item waits for it, so an Undo can't find the item not yet back in the Trash (#36).
    private var work: Task<Void, Never>?

    private func then(_ step: @escaping () async -> Bool) {
        let last = work
        work = Task {
            await last?.value
            if await step() { await changed() } else { undoManager?.removeAllActions(withTarget: self) }
        }
    }

    private func putBack() {
        register(trashAgain)
        then { [self] in
            guard let trashed else { return false }
            do {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: trashed, to: original)
            } catch {
                failed("Couldn’t Put “\(name)” Back", error)
                return false
            }
            self.trashed = nil
            return true
        }
    }

    private func trashAgain() {
        register(putBack)
        then { [self] in await trash(self) }
    }
}

func isTextFile(_ path: String) -> Bool {
    switch (path as NSString).pathExtension.lowercased() {
    case "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
         "py", "r", "dat", "def", "clo", "tikz": true
    default: false
    }
}

func isLaTeXFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "tex"
}

func fileSymbol(_ path: String, directory: Bool) -> String {
    if directory { return "folder" }
    return switch (path as NSString).pathExtension.lowercased() {
    case "tex": "text.document"
    case "bib": "books.vertical"
    case "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp": "photo"
    case "pdf": "richtext.page"
    default: "document"
    }
}
