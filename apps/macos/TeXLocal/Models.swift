import Foundation

/// The keys of the settings the editor, the PDF pane and live preview store; the raw values are what users' defaults hold.
nonisolated extension DefaultsKey {
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let editorSyntaxTheme = "editorSyntaxTheme"
    static let editorLineNumbers = "editorLineNumbers"
    static let editorAutoPair = "editorAutoPair"
    static let editorAutoComplete = "editorAutoComplete"
    static let editorSpellCheck = "editorSpellCheck"
    static let pdfPaper = "pdfPaper"
    static let liveViewer = "liveViewer"
}

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
    /// A file's, as the core sorts it by its name; a folder has none.
    var kind: FileKind?
    let children: [TreeNode]?

    var id: String { path }
    var isDirectory: Bool { type == "dir" }

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

    /// Edited as text, not previewed.
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

/// Where a forward search began, for the core to find its word in the PDF's text (`synctex_match`); the column in UTF-16.
nonisolated struct SyncSource: Sendable {
    let id: String
    let file: String
    let line: Int
    let column: Int
}

/// That word in a page's text: its UTF-16 range there.
nonisolated struct PageHit: Decodable, Sendable {
    let page: Int
    let start: Int
    let end: Int
}

/// A click on a page for `synctex_inverse`: the page's text, and the clicked letter's UTF-16 index in it.
nonisolated struct PageClick: Equatable, Sendable {
    let text: String
    let at: Int
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
