import Foundation

nonisolated enum SessionEvent: Sendable {
    case document(DocumentState)
    case outline(Analysis)
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
    case live(LiveEvent)
    case livePDF(LiveRead)

    init?(_ type: String, _ decoder: any Decoder) throws {
        func fields<T: Decodable>(_: T.Type = T.self) throws -> T { try T(from: decoder) }
        switch type {
        case "document": self = .document(try fields())
        case "outline": self = .outline(try fields())
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

nonisolated struct DocumentState: Decodable, Equatable { let path: String, error: String?, held: Bool }

nonisolated struct ReloadEvent: Decodable { let path, text: String }
nonisolated struct ClosedEvent: Decodable { let path, reason: String }
nonisolated struct RenamedEvent: Decodable { let from, to: String }
nonisolated struct ConflictEvent: Decodable {
    nonisolated enum Kind: String, Decodable { case changed, gone }
    let path: String, kind: Kind
}
nonisolated struct TreeEvent: Decodable { let tree: [TreeNode] }
nonisolated struct PathsEvent: Decodable { let paths: [String] }
nonisolated struct BuildState: Decodable { let compiling, auto, outdated: Bool }
nonisolated struct LiveEvent: Decodable { let state: LiveState, alert: Bool }

nonisolated struct BuildFinished: Decodable { let auto, announce, outdated: Bool, result: CompileResult }
nonisolated struct ChecksEvent: Decodable { let items: [LogItem] }

nonisolated struct IssuesEvent: Decodable {
    nonisolated struct Line: Decodable, Equatable {
        let line: Int
        let error: Bool
        let message: String
        let short: String
        let compact: String?
        let tokens: [SourceRange]
        let others: [String]
        let index: Int?
    }

    let path: String
    let lines: [Line]

    var byLine: [Int: Line] { Dictionary(lines.map { ($0.line, $0) }) { $1 } }
}
