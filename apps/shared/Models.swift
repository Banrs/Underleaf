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

enum ProjectTemplate: String, CaseIterable, Identifiable {
    case blank, article, report, beamer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Blank"
        case .article: "Article"
        case .report: "Report"
        case .beamer: "Presentation"
        }
    }
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

nonisolated struct LogItem: Decodable {
    let type: String
    let file: String?
    let line: Int?
    let message: String
    /// What TeX's message means here and what usually fixes it.
    let explain: String?
    let fix: Fix?

    var isError: Bool { type == "error" }

    /// Run by the session by its id (docs/core-api.md, Explanations and fixes): the app knows no fix by name.
    nonisolated struct Fix: Decodable, Equatable {
        let id, title, help: String
        /// Asked before it runs.
        let confirm: String?
    }
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

/// Every line that defines or uses a name, as a search's hits (`session_usages`).
nonisolated struct Usages: Decodable {
    /// As the source writes it: `\label{x}`, `\foo`, a file's path.
    let name: String
    let groups: [SearchGroup]
}

/// In PDF points, origin at the page's top-left: the baseline point (h, v) and the box's width and height above it.
nonisolated struct ForwardLoc: Decodable {
    let page: Double
    let h, v, width, height: Double?
    var matches: [ForwardLoc]? = nil
}

nonisolated struct InverseLoc: Decodable { let file: String, line: Int, column: Int? }

/// A line, from 1, of a project's file: where Back and Forward go, and where Quick Help's name is defined.
nonisolated struct Place: Decodable {
    let path: String
    let line: Int
}

/// Whether Back and Forward have somewhere to go, and where one went (`session_navigate`, `session_back`).
nonisolated struct Trail: Decodable {
    var back = false, forward = false
    var to: Place?
}

/// `session_quick_help`'s, for the popover.
nonisolated struct QuickHelp: Decodable {
    let title, detail: String
    let place: Place?
}

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

/// One of `session_history_list`'s: what it was taken for, and the files that differ from the one before it.
nonisolated struct Snapshot: Decodable, Identifiable {
    nonisolated struct Change: Decodable {
        nonisolated enum Kind: String, Decodable { case added, deleted, changed }

        let path: String
        let change: Kind
    }

    let id: String
    let time: Date
    let name, reason: String?
    let changed: [Change]

    private enum Keys: CodingKey { case id, time, name, reason, changed }

    /// `time` is ISO 8601, which `Core`'s plain decoder doesn't read.
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        id = try fields.decode(String.self, forKey: .id)
        time = try Date(fields.decode(String.self, forKey: .time), strategy: .iso8601)
        name = try fields.decodeIfPresent(String.self, forKey: .name)
        reason = try fields.decodeIfPresent(String.self, forKey: .reason)
        changed = try fields.decode([Change].self, forKey: .changed)
    }

    var title: String { name ?? reason ?? String(localized: "Automatic") }
}

/// A row of `session_history_compare`'s unified diff: a line in both, the snapshot's alone or now's alone, or a count of
/// unchanged lines folded away.
nonisolated struct DiffLine: Decodable { let same, removed, added: String?; let skipped: Int? }

func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}
