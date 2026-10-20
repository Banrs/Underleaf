import Foundation

nonisolated struct ProjectInfo: Decodable, Identifiable {
    let id, name: String
    let mtime: Double
    let mainFile: String

    var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}

nonisolated struct TreeNode: Decodable, Identifiable, Equatable {
    nonisolated enum Entry: String, Decodable { case file, dir }

    let type: Entry
    let name, path: String
    /// A file's, from its name; a folder has none.
    var kind: FileKind?
    let children: [TreeNode]?

    var id: String { path }
    var isDirectory: Bool { type == .dir }

    var symbol: String {
        if isDirectory { return "folder" }
        return switch kind ?? .other {
        case .tex: "text.document"
        case .bib: "books.vertical"
        case .image: "photo"
        case .pdf: "richtext.page"
        default: "document"
        }
    }
}

nonisolated enum FileKind: String, Decodable, Sendable {
    case tex, bib, image, pdf, text, other

    var isText: Bool { self == .tex || self == .bib || self == .text }

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

extension [TreeNode] {
    var flattened: [TreeNode] { flatMap { [$0] + ($0.children ?? []).flattened } }
}

nonisolated extension String {
    var parentFolder: String { (self as NSString).deletingLastPathComponent }
    var fileName: String { (self as NSString).lastPathComponent }
}

nonisolated extension NSRange {
    static func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }
}

nonisolated struct TexStatus: Decodable {
    let available: Bool
    /// "4.86".
    var latexmkVersion: String?
    var texDir, found, texpresso, texpressoDir: String?
}

nonisolated struct ProjectSettings: Decodable {
    var mainFile, engine: String
    var shellEscape, stopOnFirstError: Bool

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

/// A failed build may still have written a PDF; `stopped`: Stop, a newer build or quitting ended it.
nonisolated struct CompileResult: Decodable {
    let ok, stopped: Bool
    let pdf: String?
    let pdfChanged: Bool
    let durationMs: Int
    let errors, warnings: [LogItem]
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
    let before, match, after: String

    var id: String { "\(file):\(line):\(before.count)" }
}

nonisolated struct SearchGroup: Decodable, Identifiable {
    let file: String
    let hits: [SearchHit]

    var id: String { file }
}

/// In PDF points, origin at the page's top-left: the baseline point (h, v) and the box's width and height above it.
nonisolated struct ForwardLoc: Decodable {
    let page: Double
    let h, v, width, height: Double?
    var matches: [ForwardLoc]? = nil
}

nonisolated struct InverseLoc: Decodable { let file: String, line: Int, column: Int? }

/// Where a forward search began, for `synctex_match`; the column in UTF-16.
nonisolated struct SyncSource: Sendable {
    let id, file: String
    let line, column: Int
}

nonisolated struct PageHit: Decodable, Sendable { let page, start, end: Int }

/// For `synctex_inverse`: the page's text, and the clicked letter's UTF-16 index.
nonisolated struct PageClick: Equatable, Sendable { let text: String, at: Int }

nonisolated struct Imported: Decodable { let existing: [PathEvent] }

nonisolated struct RenameResult: Decodable {
    let from, to, mainFile: String
    let ui: UIState
}

func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}
