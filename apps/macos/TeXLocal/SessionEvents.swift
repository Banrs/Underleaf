import Foundation

// The session's answers and events (docs/core-api.md).

/// What a session's event says, decoded once, on the core's event thread (`Core`).
nonisolated enum SessionEvent: Sendable {
    case document(DocumentState)
    case saved
    case reload(ReloadEvent)
    case closed(ClosedEvent)
    case renamed(RenamedEvent)
    case conflict(ConflictEvent)
    case issues(IssuesEvent)
    case build(BuildState)
    case buildFinished(BuildFinished)
    case buildCleaned
    case tree(TreeEvent)
    case filesChanged(PathsEvent)
    case live(LiveState)
    /// A `live_document` or `live_page`, its PDF read already.
    case livePDF(LiveRead)
    case liveRestarted

    /// The event of `type`, its fields read from `decoder`; nil for a type the app has no use for.
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
        case "build": self = .build(try fields())
        case "build_finished": self = .buildFinished(try fields())
        case "build_cleaned": self = .buildCleaned
        case "tree": self = .tree(try fields())
        case "files_changed": self = .filesChanged(try fields())
        case "live": self = .live(try fields())
        case "live_document": self = .livePDF(LiveRead(try fields(LiveDocumentEvent.self)))
        case "live_page": self = .livePDF(LiveRead(try fields(LivePageEvent.self)))
        case "live_restarted": self = .liveRestarted
        default: return nil
        }
    }
}

nonisolated struct SessionOpened: Decodable, Sendable {
    let root: String
    /// The last build's, if it has one.
    let pdf: String?
    let tree: [TreeNode]
    let settings: ProjectSettings
    let ui: UIState
}

nonisolated struct Located: Decodable, Sendable { let id, path: String }
nonisolated struct UIState: Decodable, Sendable { let expandedFolders, foldedHeadings: [String] }
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

    let path: String
    let kind: Kind
}
nonisolated struct TreeEvent: Decodable { let tree: [TreeNode] }
nonisolated struct PathsEvent: Decodable { let paths: [String] }
nonisolated struct BuildState: Decodable { let compiling, auto, outdated: Bool }

nonisolated struct BuildFinished: Decodable {
    let auto, announce, outdated: Bool
    let result: CompileResult
}

nonisolated struct IssuesEvent: Decodable {
    nonisolated struct Line: Decodable {
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
    }

    let path: String
    let lines: [Line]
}
