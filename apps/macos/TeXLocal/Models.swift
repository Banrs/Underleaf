import Foundation

nonisolated struct ProjectInfo: Decodable, Identifiable {
    let id, name: String
    let mtime: Double
    let mainFile, path: String
    /// A folder opened where it is, and one no longer there.
    let opened, missing: Bool

    var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
    var folder: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

nonisolated struct TreeNode: Decodable, Identifiable, Equatable {
    nonisolated enum Entry: String, Decodable { case file, dir }

    let type: Entry
    let name, path: String
    /// A file's, from its name; a folder has none.
    var kind: FileKind?
    let children: [TreeNode]?
    /// The core's mark, as latexmk finds the main file.
    var main: Bool?

    var id: String { path }
    var isDirectory: Bool { type == .dir }

    var symbol: String {
        switch kind {
        case _ where isDirectory: "folder"
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
}

/// One setting's new value: shown at once, and sent to the session as its patch.
nonisolated struct SettingsChange {
    let patch: [String: any Sendable]
    let apply: (inout ProjectSettings) -> Void

    static func mainFile(_ path: String) -> Self { Self(patch: ["mainFile": path]) { $0.mainFile = path } }
    static func engine(_ name: String) -> Self { Self(patch: ["engine": name]) { $0.engine = name } }
    static func shellEscape(_ on: Bool) -> Self { Self(patch: ["shellEscape": on]) { $0.shellEscape = on } }
    static func stopOnFirstError(_ on: Bool) -> Self {
        Self(patch: ["stopOnFirstError": on]) { $0.stopOnFirstError = on }
    }
}

nonisolated struct LogItem: Decodable, Equatable {
    let type: String
    let file: String?
    let line: Int?
    let message: String
    /// The package or class file LaTeX didn't find, for Install.
    let missing: String?

    var isError: Bool { type == "error" }
}

/// A failed build may still have written a PDF; `stopped`: Stop, a newer build or quitting ended it.
nonisolated struct CompileResult: Decodable {
    let ok, stopped: Bool
    let pdf: String?
    let pdfChanged: Bool
    let durationMs: Int
    let errors, warnings, badBoxes: [LogItem]
    let log: String

    var failed: Bool { !ok && !stopped }
    /// The bad boxes after the warnings, as Overleaf lists its typesetting warnings: numbered on from the issues, which the
    /// session numbers alone.
    var listed: [LogItem] { errors + warnings + badBoxes }

    var durationText: String {
        Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

nonisolated struct SearchHit: Decodable, Identifiable {
    let file: String
    let line, column, length: Int
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
