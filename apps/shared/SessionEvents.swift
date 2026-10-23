import Foundation

/// A session's event (docs/core-api.md), decoded on the core's event thread (`Core`).
nonisolated enum SessionEvent: Sendable {
    case document(DocumentState)
    case saved
    case reload(ReloadEvent)
    case closed(ClosedEvent)
    case renamed(RenamedEvent)
    case conflict(ConflictEvent)
    case issues(IssuesEvent)
    case liveIssues(IssuesEvent)
    case checks(ChecksEvent)
    case build(BuildState)
    case buildFinished(BuildFinished)
    case buildCleaned
    case tree(TreeEvent)
    case filesChanged(PathsEvent)
    case live(LiveState)
    /// A `live_document` or `live_page`, its PDF read already.
    case livePDF(LiveRead)

    /// Nil for a type the app has no use for.
    init?(_ type: String, _ decoder: any Decoder) throws {
        func fields<T: Decodable>(_: T.Type = T.self) throws -> T { try T(from: decoder) }
        switch type {
        case "document": self = .document(try fields())
        case "saved": self = .saved
        case "document_reload": self = .reload(try fields())
        case "document_closed": self = .closed(try fields())
        case "document_renamed": self = .renamed(try fields())
        case "conflict": self = .conflict(try fields())
        case "issues": self = .issues(try fields())
        case "live_issues": self = .liveIssues(try fields())
        case "checks": self = .checks(try fields())
        case "build": self = .build(try fields())
        case "build_finished": self = .buildFinished(try fields())
        case "build_cleaned": self = .buildCleaned
        case "tree": self = .tree(try fields())
        case "files_changed": self = .filesChanged(try fields())
        case "live": self = .live(try fields())
        case "live_document": self = .livePDF(LiveRead(try fields(LiveDocumentEvent.self)))
        case "live_page": self = .livePDF(LiveRead(try fields(LivePageEvent.self)))
        default: return nil
        }
    }
}

nonisolated struct SessionOpened: Decodable, Sendable {
    let name, root: String
    let tree: [TreeNode]
    let settings: ProjectSettings
    let ui: UIState
}

nonisolated struct Located: Decodable, Sendable { let id, path: String }
/// The project's interface as it was left (docs/core-api.md).
nonisolated struct UIState: Decodable, Sendable {
    let expandedFolders, foldedHeadings: [String]
    let file: String?
    let line, page: Int?
    let zoom: PDFController.Zoom?
    let panel, livePreview: Bool
}
nonisolated struct Saved: Decodable, Sendable { let saved: Bool }
nonisolated struct Closed: Decodable, Sendable { let closed: Bool }
nonisolated struct Ready: Decodable, Sendable { let ready: Bool }
nonisolated struct ChosenIssue: Decodable, Sendable { let index: Int, issue: LogItem }

nonisolated struct DocumentState: Decodable, Equatable { let path: String, error: String?, held: Bool }

nonisolated struct ReloadEvent: Decodable { let path, text: String }
nonisolated struct PathEvent: Decodable, Sendable { let path: String }
/// `reason`: `gone`, `deleted`, or `closed` when the app closed it.
nonisolated struct ClosedEvent: Decodable { let path, reason: String }
nonisolated struct RenamedEvent: Decodable { let from, to: String }
nonisolated struct ConflictEvent: Decodable {
    nonisolated enum Kind: String, Decodable { case changed, gone }
    let path: String, kind: Kind
}
nonisolated struct TreeEvent: Decodable { let tree: [TreeNode] }
nonisolated struct PathsEvent: Decodable { let paths: [String] }
nonisolated struct BuildState: Decodable { let compiling, auto, outdated: Bool }

nonisolated struct BuildFinished: Decodable { let auto, announce, outdated: Bool, result: CompileResult }
nonisolated struct ChecksEvent: Decodable { let items: [LogItem] }

nonisolated struct IssuesEvent: Decodable {
    nonisolated struct Line: Decodable, Equatable {
        let line: Int
        let error: Bool
        let message: String
        /// On one line, without LaTeX's words for what the symbol says already.
        let short: String
        /// An undefined command's, in fewer words that keep its name.
        let compact: String?
        /// Where the line has the undefined command, from its start.
        let tokens: [SourceRange]
        let others: [String]
        /// Where the line's issues start in the session's list; none for Live Preview's.
        let index: Int?
    }

    let path: String
    let lines: [Line]

    var byLine: [Int: Line] { Dictionary(lines.map { ($0.line, $0) }) { $1 } }
}
