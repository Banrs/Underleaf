import Foundation
import Observation

nonisolated protocol WireRequest: Encodable, Sendable {
    associatedtype Reply: Decodable & Sendable
    static var command: String { get }
}

nonisolated struct Done: Decodable, Hashable, Sendable {
    init() {}

    init(from decoder: any Decoder) throws {
        guard try decoder.singleValueContainer().decodeNil() else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not null"))
        }
    }
}

nonisolated struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

nonisolated extension Decoder {
    func strict<Key: CodingKey & CaseIterable>(_: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let known = Set(Key.allCases.map(\.stringValue))
        if let unknown = try container(keyedBy: WireKey.self).allKeys.first(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [unknown], debugDescription: "Unknown key"))
        }
        return try container(keyedBy: Key.self)
    }
}

nonisolated protocol LibraryRequest: WireRequest {}

nonisolated protocol SessionRequest: WireRequest {}

nonisolated protocol SourceRequest: WireRequest {}

nonisolated protocol SyntaxRequest: WireRequest {}

nonisolated struct AcceptCompletion: SourceRequest {
    typealias Reply = Insertion?
    static let command = "AcceptCompletion"

    var index: Int
    var caret: Int
}

nonisolated struct Analysis: Decodable, Hashable, Sendable {
    var tree: [OutlineNode]
    var words: Int
    var headingStyles: [HeadingStyle]

    enum CodingKeys: String, CodingKey, CaseIterable { case tree, words, headingStyles }
}

nonisolated extension Analysis {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        tree = try wire.decode([OutlineNode].self, forKey: .tree)
        words = try wire.decode(Int.self, forKey: .words)
        headingStyles = try wire.decode([HeadingStyle].self, forKey: .headingStyles)
    }
}

nonisolated enum Answered<Payload: Decodable & Sendable>: Decodable, Sendable {
    case ok(Payload)
    case error(CoreError)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Answered {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "ok": self = .ok(try wire.decode(Payload.self, forKey: .value))
        case "error": self = .error(try wire.decode(CoreError.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated struct ApplyFix: SessionRequest {
    typealias Reply = Fixed?
    static let command = "ApplyFix"

    var id: String
}

nonisolated struct BuildFinished: Decodable, Hashable, Sendable {
    var auto: Bool
    var announce: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case auto, announce }
}

nonisolated extension BuildFinished {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        auto = try wire.decode(Bool.self, forKey: .auto)
        announce = try wire.decode(Bool.self, forKey: .announce)
    }
}

nonisolated struct BuildState: Decodable, Hashable, Sendable {
    var compiling: Bool
    var auto: Bool
    var outdated: Bool
    var result: CompileResult?
    var issues: [LogItem]
    var lines: [String: [IssueLine]]

    enum CodingKeys: String, CodingKey, CaseIterable { case compiling, auto, outdated, result, issues, lines }
}

nonisolated extension BuildState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        compiling = try wire.decode(Bool.self, forKey: .compiling)
        auto = try wire.decode(Bool.self, forKey: .auto)
        outdated = try wire.decode(Bool.self, forKey: .outdated)
        result = try wire.decode(CompileResult?.self, forKey: .result)
        issues = try wire.decode([LogItem].self, forKey: .issues)
        lines = try wire.decode([String: [IssueLine]].self, forKey: .lines)
    }
}

nonisolated struct Change: Decodable, Hashable, Sendable {
    var edits: [TextEdit]
    var selections: [TextRange]

    enum CodingKeys: String, CodingKey, CaseIterable { case edits, selections }
}

nonisolated extension Change {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        edits = try wire.decode([TextEdit].self, forKey: .edits)
        selections = try wire.decode([TextRange].self, forKey: .selections)
    }
}

nonisolated enum ChangeKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case added, deleted, changed
}

nonisolated struct ChangedFile: Decodable, Hashable, Sendable {
    var path: String
    var change: ChangeKind

    enum CodingKeys: String, CodingKey, CaseIterable { case path, change }
}

nonisolated extension ChangedFile {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        change = try wire.decode(ChangeKind.self, forKey: .change)
    }
}

nonisolated struct CheckTex: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "CheckTex"
}

nonisolated enum Checker: String, Encodable, CaseIterable, Hashable, Sendable {
    case spelling, writingTools
}

nonisolated struct Clash: Decodable, Hashable, Sendable {
    var path: String
    var keepBoth: String

    enum CodingKeys: String, CodingKey, CaseIterable { case path, keepBoth }
}

nonisolated extension Clash {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        keepBoth = try wire.decode(String.self, forKey: .keepBoth)
    }
}

nonisolated struct Clean: SessionRequest {
    typealias Reply = Done
    static let command = "Clean"
}

nonisolated struct CloseProject: SessionRequest {
    typealias Reply = Bool
    static let command = "CloseProject"
}

nonisolated struct CodeRanges: SourceRequest {
    typealias Reply = [TextRange]
    static let command = "CodeRanges"

    var selection: TextRange
    var checker: Checker
}

nonisolated struct CompareVersion: SessionRequest {
    typealias Reply = [DiffLine]
    static let command = "CompareVersion"

    var id: String
    var path: String
}

nonisolated struct Compile: SessionRequest {
    typealias Reply = Done
    static let command = "Compile"

    var auto: Bool
}

nonisolated struct CompileResult: Decodable, Hashable, Sendable {
    var ok: Bool
    var stopped: Bool
    var durationMs: UInt64
    var pdf: String?
    var badBoxes: [LogItem]

    enum CodingKeys: String, CodingKey, CaseIterable { case ok, stopped, durationMs, pdf, badBoxes }
}

nonisolated extension CompileResult {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        ok = try wire.decode(Bool.self, forKey: .ok)
        stopped = try wire.decode(Bool.self, forKey: .stopped)
        durationMs = try wire.decode(UInt64.self, forKey: .durationMs)
        pdf = try wire.decode(String?.self, forKey: .pdf)
        badBoxes = try wire.decode([LogItem].self, forKey: .badBoxes)
    }
}

nonisolated struct Complete: SourceRequest {
    typealias Reply = Completions?
    static let command = "Complete"

    var caret: Int
    var explicit: Bool
}

nonisolated enum Completing: String, Decodable, CaseIterable, Hashable, Sendable {
    case keep, offer, close
}

nonisolated struct Completion: Decodable, Hashable, Sendable {
    var label: String
    var text: String
    var fields: [SnippetField]
    var detail: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case label, text, fields, detail }
}

nonisolated extension Completion {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        label = try wire.decode(String.self, forKey: .label)
        text = try wire.decode(String.self, forKey: .text)
        fields = try wire.decode([SnippetField].self, forKey: .fields)
        detail = try wire.decodeIfPresent(String.self, forKey: .detail)
    }
}

nonisolated struct Completions: Decodable, Hashable, Sendable {
    var start: Int
    var kind: SymbolKind
    var items: [Completion]

    enum CodingKeys: String, CodingKey, CaseIterable { case start, kind, items }
}

nonisolated extension Completions {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        start = try wire.decode(Int.self, forKey: .start)
        kind = try wire.decode(SymbolKind.self, forKey: .kind)
        items = try wire.decode([Completion].self, forKey: .items)
    }
}

nonisolated struct Composing: SessionRequest {
    typealias Reply = Done
    static let command = "Composing"

    var path: String
    var composing: Bool
}

nonisolated struct Conflict: Decodable, Hashable, Sendable {
    var path: String
    var kind: DiskConflict

    enum CodingKeys: String, CodingKey, CaseIterable { case path, kind }
}

nonisolated extension Conflict {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        kind = try wire.decode(DiskConflict.self, forKey: .kind)
    }
}

nonisolated struct CoreError: Decodable, Hashable, Sendable {
    var kind: ErrorKind
    var message: Message

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, message }
}

nonisolated extension CoreError {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(ErrorKind.self, forKey: .kind)
        message = try wire.decode(Message.self, forKey: .message)
    }
}

nonisolated struct CreateEntry: SessionRequest {
    typealias Reply = String
    static let command = "CreateEntry"

    var folder: String
    var name: String
    var dir: Bool
}

nonisolated struct CreateProject: LibraryRequest {
    typealias Reply = ProjectInfo
    static let command = "CreateProject"

    var name: String
    var template: ProjectTemplate
    var engine: Engine?
}

nonisolated struct Definition: Decodable, Hashable, Sendable {
    var kind: SymbolKind
    var name: String
    var places: [FilePlace]

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, name, places }
}

nonisolated extension Definition {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(SymbolKind.self, forKey: .kind)
        name = try wire.decode(String.self, forKey: .name)
        places = try wire.decode([FilePlace].self, forKey: .places)
    }
}

nonisolated struct DefinitionAt: SourceRequest {
    typealias Reply = Definition?
    static let command = "DefinitionAt"

    var at: Int
}

nonisolated struct DeleteBackward: SourceRequest {
    typealias Reply = Keystroke
    static let command = "DeleteBackward"

    var selection: TextRange
    var autoPair: Bool
}

nonisolated struct DeleteLines: SourceRequest {
    typealias Reply = Change
    static let command = "DeleteLines"

    var selections: [TextRange]
}

nonisolated enum DiffLine: Decodable, Hashable, Sendable {
    case same(String)
    case removed(String)
    case added(String)
    case skipped(Int)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension DiffLine {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "same": self = .same(try wire.decode(String.self, forKey: .value))
        case "removed": self = .removed(try wire.decode(String.self, forKey: .value))
        case "added": self = .added(try wire.decode(String.self, forKey: .value))
        case "skipped": self = .skipped(try wire.decode(Int.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated enum DiskConflict: String, Decodable, CaseIterable, Hashable, Sendable {
    case changed, gone
}

nonisolated struct DocumentEdits: Decodable, Hashable, Sendable {
    var path: String
    var version: UInt64
    var edits: [TextEdit]

    enum CodingKeys: String, CodingKey, CaseIterable { case path, version, edits }
}

nonisolated extension DocumentEdits {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        version = try wire.decode(UInt64.self, forKey: .version)
        edits = try wire.decode([TextEdit].self, forKey: .edits)
    }
}

nonisolated struct DocumentState: Decodable, Hashable, Sendable {
    var path: String
    var error: Message?
    var held: DiskConflict?

    enum CodingKeys: String, CodingKey, CaseIterable { case path, error, held }
}

nonisolated extension DocumentState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        error = try wire.decode(Message?.self, forKey: .error)
        held = try wire.decode(DiskConflict?.self, forKey: .held)
    }
}

nonisolated struct DuplicateLines: SourceRequest {
    typealias Reply = Change
    static let command = "DuplicateLines"

    var selections: [TextRange]
}

nonisolated struct DuplicateProject: LibraryRequest {
    typealias Reply = ProjectInfo
    static let command = "DuplicateProject"

    var id: String
    var name: String
}

nonisolated struct EndSnippet: SourceRequest {
    typealias Reply = Bool
    static let command = "EndSnippet"
}

nonisolated enum Engine: String, Codable, CaseIterable, Hashable, Sendable {
    case pdflatex, xelatex, lualatex

    var title: String {
        switch self {
        case .pdflatex: "pdfLaTeX"
        case .xelatex: "XeLaTeX"
        case .lualatex: "LuaLaTeX"
        }
    }
}

nonisolated enum ErrorKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case invalid, denied, notFound, conflict, unavailable, `internal`
}

nonisolated enum Event: Decodable, Hashable, Sendable {
    case section(SessionSection)
    case documentReload(String)
    case renamed(Renamed)
    case conflict(Conflict)
    case filesChanged([String])
    case buildFinished(BuildFinished)
    case liveAlert
    case livePage(LivePage)
    case liveDocument(LiveDocument)
    case liveFollow(ForwardLoc)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Event {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "section": self = .section(try wire.decode(SessionSection.self, forKey: .value))
        case "documentReload": self = .documentReload(try wire.decode(String.self, forKey: .value))
        case "renamed": self = .renamed(try wire.decode(Renamed.self, forKey: .value))
        case "conflict": self = .conflict(try wire.decode(Conflict.self, forKey: .value))
        case "filesChanged": self = .filesChanged(try wire.decode([String].self, forKey: .value))
        case "buildFinished": self = .buildFinished(try wire.decode(BuildFinished.self, forKey: .value))
        case "liveAlert": self = .liveAlert
        case "livePage": self = .livePage(try wire.decode(LivePage.self, forKey: .value))
        case "liveDocument": self = .liveDocument(try wire.decode(LiveDocument.self, forKey: .value))
        case "liveFollow": self = .liveFollow(try wire.decode(ForwardLoc.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated struct ExportZip: SessionRequest {
    typealias Reply = Done
    static let command = "ExportZip"

    var dest: String
    var forArxiv: Bool
}

nonisolated enum FileKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case tex, bib, image, pdf, text, other
}

nonisolated struct FilePlace: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var column: Int
    var length: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case file, line, column, length }
}

nonisolated extension FilePlace {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        file = try wire.decode(String.self, forKey: .file)
        line = try wire.decode(Int.self, forKey: .line)
        column = try wire.decode(Int.self, forKey: .column)
        length = try wire.decode(Int.self, forKey: .length)
    }
}

nonisolated struct FindUsages: SessionRequest {
    typealias Reply = Usages?
    static let command = "FindUsages"

    var path: String
    var offset: Int
}

nonisolated struct Fix: Decodable, Hashable, Sendable {
    var id: String
    var title: Message
    var help: Message
    var confirm: Message?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, help, confirm }
}

nonisolated extension Fix {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(String.self, forKey: .id)
        title = try wire.decode(Message.self, forKey: .title)
        help = try wire.decode(Message.self, forKey: .help)
        confirm = try wire.decodeIfPresent(Message.self, forKey: .confirm)
    }
}

nonisolated struct Fixed: Decodable, Hashable, Sendable {
    var edits: DocumentEdits?

    enum CodingKeys: String, CodingKey, CaseIterable { case edits }
}

nonisolated extension Fixed {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        edits = try wire.decode(DocumentEdits?.self, forKey: .edits)
    }
}

nonisolated struct Fold: Decodable, Hashable, Sendable {
    var line: Int
    var end: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case line, end }
}

nonisolated extension Fold {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        line = try wire.decode(Int.self, forKey: .line)
        end = try wire.decode(Int.self, forKey: .end)
    }
}

nonisolated struct Folds: SourceRequest {
    typealias Reply = [Fold]
    static let command = "Folds"
}

nonisolated struct ForgetFolder: LibraryRequest {
    typealias Reply = Done
    static let command = "ForgetFolder"

    var id: String
}

nonisolated struct ForwardLoc: Decodable, Hashable, Sendable {
    var page: Double
    var h: Double?
    var v: Double?
    var width: Double?
    var height: Double?
    var matches: [ForwardLoc]

    enum CodingKeys: String, CodingKey, CaseIterable { case page, h, v, width, height, matches }
}

nonisolated extension ForwardLoc {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        page = try wire.decode(Double.self, forKey: .page)
        h = try wire.decode(Double?.self, forKey: .h)
        v = try wire.decode(Double?.self, forKey: .v)
        width = try wire.decode(Double?.self, forKey: .width)
        height = try wire.decode(Double?.self, forKey: .height)
        matches = try wire.decode([ForwardLoc].self, forKey: .matches)
    }
}

nonisolated struct FreeProjectName: LibraryRequest {
    typealias Reply = String
    static let command = "FreeProjectName"
}

nonisolated struct Heading: Decodable, Hashable, Sendable {
    var command: String
    var level: String
    var title: String
    var untitled: Bool
    var line: Int
    var file: String

    enum CodingKeys: String, CodingKey, CaseIterable { case command, level, title, untitled, line, file }
}

nonisolated extension Heading {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        command = try wire.decode(String.self, forKey: .command)
        level = try wire.decode(String.self, forKey: .level)
        title = try wire.decode(String.self, forKey: .title)
        untitled = try wire.decode(Bool.self, forKey: .untitled)
        line = try wire.decode(Int.self, forKey: .line)
        file = try wire.decode(String.self, forKey: .file)
    }
}

nonisolated struct HeadingStyle: Decodable, Hashable, Sendable {
    var title: String
    var command: String

    enum CodingKeys: String, CodingKey, CaseIterable { case title, command }
}

nonisolated extension HeadingStyle {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        title = try wire.decode(String.self, forKey: .title)
        command = try wire.decode(String.self, forKey: .command)
    }
}

nonisolated struct HeadingStyles: SyntaxRequest {
    typealias Reply = [HeadingStyle]
    static let command = "HeadingStyles"
}

nonisolated enum HighlightKind: UInt32, CaseIterable, Hashable, Sendable {
    case command = 0
    case argument = 1
    case maths = 2
    case comment = 3
    case invalid = 4
}

nonisolated enum ImportConflict: String, Encodable, CaseIterable, Hashable, Sendable {
    case replace, keepBoth
}

nonisolated struct ImportFiles: SessionRequest {
    typealias Reply = Imported
    static let command = "ImportFiles"

    var dir: String
    var paths: [String]
    var conflict: ImportConflict?
}

nonisolated struct Imported: Decodable, Hashable, Sendable {
    var existing: [Clash]

    enum CodingKeys: String, CodingKey, CaseIterable { case existing }
}

nonisolated extension Imported {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        existing = try wire.decode([Clash].self, forKey: .existing)
    }
}

nonisolated struct IncludeGraphics: SyntaxRequest {
    typealias Reply = String?
    static let command = "IncludeGraphics"

    var path: String
    var into: String
}

nonisolated struct InsertBlock: SourceRequest {
    typealias Reply = Insertion?
    static let command = "InsertBlock"

    var id: String
    var selection: TextRange
}

nonisolated struct InsertNewline: SourceRequest {
    typealias Reply = Keystroke
    static let command = "InsertNewline"

    var selection: TextRange
}

nonisolated struct InsertSymbol: SourceRequest {
    typealias Reply = Insertion
    static let command = "InsertSymbol"

    var command: String
    var selection: TextRange
}

nonisolated struct InsertTab: SourceRequest {
    typealias Reply = Tabbing
    static let command = "InsertTab"

    var selections: [TextRange]
    var step: Int
}

nonisolated struct Insertion: Decodable, Hashable, Sendable {
    var edit: TextEdit
    var caret: Int
    var fields: [SnippetField]

    enum CodingKeys: String, CodingKey, CaseIterable { case edit, caret, fields }
}

nonisolated extension Insertion {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        edit = try wire.decode(TextEdit.self, forKey: .edit)
        caret = try wire.decode(Int.self, forKey: .caret)
        fields = try wire.decode([SnippetField].self, forKey: .fields)
    }
}

nonisolated struct InstallTex: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "InstallTex"
}

nonisolated struct InverseLoc: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var column: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case file, line, column }
}

nonisolated extension InverseLoc {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        file = try wire.decode(String.self, forKey: .file)
        line = try wire.decode(Int.self, forKey: .line)
        column = try wire.decode(Int?.self, forKey: .column)
    }
}

nonisolated struct IssueLine: Decodable, Hashable, Sendable {
    var line: Int
    var error: Bool
    var message: Message
    var short: Message
    var compact: Message?
    var tokens: [TextRange]
    var others: [Message]
    var index: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case line, error, message, short, compact, tokens, others, index }
}

nonisolated extension IssueLine {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        line = try wire.decode(Int.self, forKey: .line)
        error = try wire.decode(Bool.self, forKey: .error)
        message = try wire.decode(Message.self, forKey: .message)
        short = try wire.decode(Message.self, forKey: .short)
        compact = try wire.decode(Message?.self, forKey: .compact)
        tokens = try wire.decode([TextRange].self, forKey: .tokens)
        others = try wire.decode([Message].self, forKey: .others)
        index = try wire.decode(Int?.self, forKey: .index)
    }
}

nonisolated struct Keystroke: Decodable, Hashable, Sendable {
    var edit: TextEdit?
    var selection: TextRange?
    var partner: Int?
    var completions: Completing

    enum CodingKeys: String, CodingKey, CaseIterable { case edit, selection, partner, completions }
}

nonisolated extension Keystroke {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        edit = try wire.decode(TextEdit?.self, forKey: .edit)
        selection = try wire.decode(TextRange?.self, forKey: .selection)
        partner = try wire.decode(Int?.self, forKey: .partner)
        completions = try wire.decode(Completing.self, forKey: .completions)
    }
}

nonisolated struct KillAll: LibraryRequest {
    typealias Reply = Done
    static let command = "KillAll"
}

nonisolated enum LibrarySection: Decodable, Hashable, Sendable {
    case projects([ProjectInfo])
    case tex(TexStatus)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension LibrarySection {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "projects": self = .projects(try wire.decode([ProjectInfo].self, forKey: .value))
        case "tex": self = .tex(try wire.decode(TexStatus.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated enum Lifecycle: Decodable, Hashable, Sendable {
    case `open`
    case closing
    case closed
    case stopped(Stopped)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Lifecycle {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "open": self = .open
        case "closing": self = .closing
        case "closed": self = .closed
        case "stopped": self = .stopped(try wire.decode(Stopped.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated struct ListMenus: SyntaxRequest {
    typealias Reply = Menus
    static let command = "ListMenus"
}

nonisolated struct ListVersions: SessionRequest {
    typealias Reply = [Snapshot]
    static let command = "ListVersions"
}

nonisolated struct LiveCaret: SessionRequest {
    typealias Reply = Done
    static let command = "LiveCaret"

    var path: String
    var offset: Int
}

nonisolated struct LiveDocument: Decodable, Hashable, Sendable {
    var path: String
    var changed: [PageRange]

    enum CodingKeys: String, CodingKey, CaseIterable { case path, changed }
}

nonisolated extension LiveDocument {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        changed = try wire.decode([PageRange].self, forKey: .changed)
    }
}

nonisolated struct LiveLog: SessionRequest {
    typealias Reply = Done
    static let command = "LiveLog"

    var shown: Bool
}

nonisolated struct LivePage: Decodable, Hashable, Sendable {
    var page: Int
    var pdf: Data

    enum CodingKeys: String, CodingKey, CaseIterable { case page, pdf }
}

nonisolated extension LivePage {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        page = try wire.decode(Int.self, forKey: .page)
        pdf = try wire.decode(Data.self, forKey: .pdf)
    }
}

nonisolated enum LivePhase: String, Decodable, CaseIterable, Hashable, Sendable {
    case stopped, starting, running
}

nonisolated struct LiveState: Decodable, Hashable, Sendable {
    var phase: LivePhase
    var engine: Engine
    var halted: Bool
    var failures: [Message]
    var lines: [String: [IssueLine]]

    enum CodingKeys: String, CodingKey, CaseIterable { case phase, engine, halted, failures, lines }
}

nonisolated extension LiveState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        phase = try wire.decode(LivePhase.self, forKey: .phase)
        engine = try wire.decode(Engine.self, forKey: .engine)
        halted = try wire.decode(Bool.self, forKey: .halted)
        failures = try wire.decode([Message].self, forKey: .failures)
        lines = try wire.decode([String: [IssueLine]].self, forKey: .lines)
    }
}

nonisolated struct LiveView: SessionRequest {
    typealias Reply = Done
    static let command = "LiveView"

    var first: Int
    var last: Int
}

nonisolated struct Log: Decodable, Hashable, Sendable {
    var level: LogLevel
    var text: String

    enum CodingKeys: String, CodingKey, CaseIterable { case level, text }
}

nonisolated extension Log {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        level = try wire.decode(LogLevel.self, forKey: .level)
        text = try wire.decode(String.self, forKey: .text)
    }
}

nonisolated struct LogItem: Decodable, Hashable, Sendable {
    var kind: Severity
    var file: String?
    var line: Int?
    var message: Message
    var explain: Message?
    var fix: Fix?

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, file, line, message, explain, fix }
}

nonisolated extension LogItem {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(Severity.self, forKey: .kind)
        file = try wire.decode(String?.self, forKey: .file)
        line = try wire.decode(Int?.self, forKey: .line)
        message = try wire.decode(Message.self, forKey: .message)
        explain = try wire.decodeIfPresent(Message.self, forKey: .explain)
        fix = try wire.decodeIfPresent(Fix.self, forKey: .fix)
    }
}

nonisolated enum LogLevel: String, Decodable, CaseIterable, Hashable, Sendable {
    case error, fault
}

nonisolated struct LookUp: SessionRequest {
    typealias Reply = QuickHelp?
    static let command = "LookUp"

    var path: String
    var offset: Int
}

nonisolated struct MapSelections: SourceRequest {
    typealias Reply = [TextRange]
    static let command = "MapSelections"

    var edits: [TextEdit]
    var selections: [TextRange]
}

nonisolated struct MathAt: SourceRequest {
    typealias Reply = MathPreview?
    static let command = "MathAt"

    var caret: Int
}

nonisolated struct MathPreview: Decodable, Hashable, Sendable {
    var start: Int
    var tex: String
    var display: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case start, tex, display }
}

nonisolated extension MathPreview {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        start = try wire.decode(Int.self, forKey: .start)
        tex = try wire.decode(String.self, forKey: .tex)
        display = try wire.decode(Bool.self, forKey: .display)
    }
}

nonisolated struct MathSvg: Decodable, Hashable, Sendable {
    var svg: String
    var width: Double
    var height: Double

    enum CodingKeys: String, CodingKey, CaseIterable { case svg, width, height }
}

nonisolated extension MathSvg {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        svg = try wire.decode(String.self, forKey: .svg)
        width = try wire.decode(Double.self, forKey: .width)
        height = try wire.decode(Double.self, forKey: .height)
    }
}

nonisolated struct Menus: Decodable, Hashable, Sendable {
    var templates: Templates
    var symbolGroups: [SymbolGroup]

    enum CodingKeys: String, CodingKey, CaseIterable { case templates, symbolGroups }
}

nonisolated extension Menus {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        templates = try wire.decode(Templates.self, forKey: .templates)
        symbolGroups = try wire.decode([SymbolGroup].self, forKey: .symbolGroups)
    }
}

nonisolated struct Message: Decodable, Hashable, Sendable {
    var id: MessageID
    var args: [String: String]
    var text: String

    enum CodingKeys: String, CodingKey, CaseIterable { case id, args, text }
}

nonisolated extension Message {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(MessageID.self, forKey: .id)
        args = try wire.decode([String: String].self, forKey: .args)
        text = try wire.decode(String.self, forKey: .text)
    }
}

nonisolated enum MessageID: String, Decodable, CaseIterable, Hashable, Sendable {
    case invalidArguments = "invalid_arguments"
    case unknownCommand = "unknown_command"
    case tex
    case packageNotInstalled = "package_not_installed"
    case fileNotFound = "file_not_found"
    case undefinedCommand = "undefined_command"
    case undefinedEnvironment = "undefined_environment"
    case missingDollar = "missing_dollar"
    case extraBrace = "extra_brace"
    case missingBrace = "missing_brace"
    case runawayArgument = "runaway_argument"
    case misplacedAmpersand = "misplaced_ampersand"
    case extraAmpersand = "extra_ampersand"
    case mismatchedEnd = "mismatched_end"
    case beforeDocument = "before_document"
    case preambleOnly = "preamble_only"
    case noLineToEnd = "no_line_to_end"
    case optionClash = "option_clash"
    case emergencyStop = "emergency_stop"
    case undefinedCitation = "undefined_citation"
    case unicodeCharacter = "unicode_character"
    case needsXelatex = "needs_xelatex"
    case commandDefined = "command_defined"
    case needsShellEscape = "needs_shell_escape"
    case installTitle = "install_title"
    case installHelp = "install_help"
    case addPackageTitle = "add_package_title"
    case addPackageHelp = "add_package_help"
    case xelatexTitle = "xelatex_title"
    case xelatexHelp = "xelatex_help"
    case shellEscapeTitle = "shell_escape_title"
    case shellEscapeHelp = "shell_escape_help"
    case shellEscapeConfirm = "shell_escape_confirm"
    case endWithoutBegin = "end_without_begin"
    case endedByAnother = "ended_by_another"
    case nothingToClose = "nothing_to_close"
    case openAtParagraphEnd = "open_at_paragraph_end"
    case neverClosed = "never_closed"
    case neverEnded = "never_ended"
    case labelDefinedTwice = "label_defined_twice"
    case citationDefinedTwice = "citation_defined_twice"
    case noLabel = "no_label"
    case noCitation = "no_citation"
    case noFile = "no_file"
    case ioError = "io_error"
    case unexpected
    case atPath = "at_path"
    case invalidCommand = "invalid_command"
    case unreadableArguments = "unreadable_arguments"
    case invalidJson = "invalid_json"
    case noSource = "no_source"
    case notEditable = "not_editable"
    case noSuchSession = "no_such_session"
    case sessionOpen = "session_open"
    case projectOpen = "project_open"
    case sharesFolder = "shares_folder"
    case sessionStopped = "session_stopped"
    case wentWrong = "went_wrong"
    case stoppedSaved = "stopped_saved"
    case stoppedUnsaved = "stopped_unsaved"
    case badProjectId = "bad_project_id"
    case noSuchProject = "no_such_project"
    case missingPath = "missing_path"
    case pathEscapes = "path_escapes"
    case reservedFile = "reserved_file"
    case buildFolder = "build_folder"
    case dashSegment = "dash_segment"
    case invalidName = "invalid_name"
    case notFound = "not_found"
    case destinationExists = "destination_exists"
    case intoItself = "into_itself"
    case rollbackFailed = "rollback_failed"
    case mainFileInside = "main_file_inside"
    case mainFileTrash = "main_file_trash"
    case noPermission = "no_permission"
    case readOnlyVolume = "read_only_volume"
    case diskFull = "disk_full"
    case notSaved = "not_saved"
    case trashFailed = "trash_failed"
    case noTrash = "no_trash"
    case unreadable
    case overOneMb = "over_one_mb"
    case openedElsewhere = "opened_elsewhere"
    case projectExists = "project_exists"
    case closeBeforeRenaming = "close_before_renaming"
    case closeBeforeTrashing = "close_before_trashing"
    case closeBeforeForgetting = "close_before_forgetting"
    case onlyOpenedForgotten = "only_opened_forgotten"
    case folderMoved = "folder_moved"
    case holdsLibrary = "holds_library"
    case tooManyFiles = "too_many_files"
    case zipTooManyFiles = "zip_too_many_files"
    case noTex = "no_tex"
    case notAProject = "not_a_project"
    case notAZip = "not_a_zip"
    case zipTooLarge = "zip_too_large"
    case samePlace = "same_place"
    case existsAlready = "exists_already"
    case openedNotDuplicated = "opened_not_duplicated"
    case arxivShellEscape = "arxiv_shell_escape"
    case arxivLualatex = "arxiv_lualatex"
    case notInProject = "not_in_project"
    case tooLargeToEdit = "too_large_to_edit"
    case notUtf8 = "not_utf8"
    case documentNotOpen = "document_not_open"
    case answerUnfit = "answer_unfit"
    case changedOnDisk = "changed_on_disk"
    case editsUnsaved = "edits_unsaved"
    case oneDocument = "one_document"
    case notUtf8Name = "not_utf8_name"
    case notUtf8File = "not_utf8_file"
    case tooLargeToKeep = "too_large_to_keep"
    case renamedSymbolUnfit = "renamed_symbol_unfit"
    case badLabelName = "bad_label_name"
    case badCitationName = "bad_citation_name"
    case labelExists = "label_exists"
    case citationExists = "citation_exists"
    case versionNeedsName = "version_needs_name"
    case onlyTextCompared = "only_text_compared"
    case versionGone = "version_gone"
    case badVersionId = "bad_version_id"
    case mainFileMissing = "main_file_missing"
    case timedOut = "timed_out"
    case latexmkUnstarted = "latexmk_unstarted"
    case noPdfMade = "no_pdf_made"
    case latexmkFailed = "latexmk_failed"
    case compactUndefined = "compact_undefined"
    case compactShellEscape = "compact_shell_escape"
    case noPdfYet = "no_pdf_yet"
    case noSynctex = "no_synctex"
    case invalidLine = "invalid_line"
    case noMatchInPdf = "no_match_in_pdf"
    case noOutputHere = "no_output_here"
    case invalidPdfPlace = "invalid_pdf_place"
    case noMatchInSource = "no_match_in_source"
    case noSourceFile = "no_source_file"
    case noLatexmk = "no_latexmk"
    case noTexpressoThere = "no_texpresso_there"
    case notAFileName = "not_a_file_name"
    case noPackageHas = "no_package_has"
    case installCancelled = "install_cancelled"
    case installTimedOut = "install_timed_out"
    case texliveOlder = "texlive_older"
    case repositoryUnreachable = "repository_unreachable"
    case tlmgrFailed = "tlmgr_failed"
    case miktexInstalls = "miktex_installs"
    case noTlmgr = "no_tlmgr"
    case noHome = "no_home"
    case tinytexThere = "tinytex_there"
    case noTinytexBundle = "no_tinytex_bundle"
    case tinytexMismatch = "tinytex_mismatch"
    case tinytexUnpackFailed = "tinytex_unpack_failed"
    case githubUnreachable = "github_unreachable"
    case tinytexStalled = "tinytex_stalled"
    case tinytexDownloadFailed = "tinytex_download_failed"
    case noTinytexTlmgr = "no_tinytex_tlmgr"
    case liveUnpatched = "live_unpatched"
    case liveNoMain = "live_no_main"
    case noTexpresso = "no_texpresso"
    case texpressoUnstarted = "texpresso_unstarted"
    case texpressoUnsynced = "texpresso_unsynced"
    case texpressoExited = "texpresso_exited"
    case texpressoUnsent = "texpresso_unsent"
    case viewerStopped = "viewer_stopped"
}

nonisolated struct MoveLines: SourceRequest {
    typealias Reply = Change?
    static let command = "MoveLines"

    var selections: [TextRange]
    var up: Bool
}

nonisolated struct Open: SessionRequest {
    typealias Reply = String?
    static let command = "Open"

    var path: String
}

nonisolated struct OpenFile: Decodable, Hashable, Sendable {
    var path: String
    var kind: FileKind

    enum CodingKeys: String, CodingKey, CaseIterable { case path, kind }
}

nonisolated extension OpenFile {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        kind = try wire.decode(FileKind.self, forKey: .kind)
    }
}

nonisolated struct OpenPath: LibraryRequest {
    typealias Reply = Opening
    static let command = "OpenPath"

    var path: String
}

nonisolated struct OpenProject: SessionRequest {
    typealias Reply = UiState
    static let command = "OpenProject"

    var id: String
    var autoCompile: Bool
}

nonisolated struct Opening: Decodable, Hashable, Sendable {
    var project: ProjectInfo
    var file: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case project, file }
}

nonisolated extension Opening {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        project = try wire.decode(ProjectInfo.self, forKey: .project)
        file = try wire.decode(String?.self, forKey: .file)
    }
}

nonisolated struct OutlineNode: Decodable, Hashable, Sendable {
    var index: Int
    var heading: Heading
    var foldKey: String
    var words: Int
    var children: [OutlineNode]?

    enum CodingKeys: String, CodingKey, CaseIterable { case index, heading, foldKey, words, children }
}

nonisolated extension OutlineNode {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        index = try wire.decode(Int.self, forKey: .index)
        heading = try wire.decode(Heading.self, forKey: .heading)
        foldKey = try wire.decode(String.self, forKey: .foldKey)
        words = try wire.decode(Int.self, forKey: .words)
        children = try wire.decodeIfPresent([OutlineNode].self, forKey: .children)
    }
}

nonisolated struct PageClick: Encodable, Hashable, Sendable {
    var text: String
    var at: Int
}

nonisolated struct PageRange: Decodable, Hashable, Sendable {
    var first: Int
    var last: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case first, last }
}

nonisolated extension PageRange {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        first = try wire.decode(Int.self, forKey: .first)
        last = try wire.decode(Int.self, forKey: .last)
    }
}

nonisolated struct Partner: SourceRequest {
    typealias Reply = Int?
    static let command = "Partner"

    var at: Int
}

nonisolated struct PdfHit: Decodable, Hashable, Sendable {
    var page: Int
    var start: Int
    var end: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case page, start, end }
}

nonisolated extension PdfHit {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        page = try wire.decode(Int.self, forKey: .page)
        start = try wire.decode(Int.self, forKey: .start)
        end = try wire.decode(Int.self, forKey: .end)
    }
}

nonisolated struct PdfPage: Encodable, Hashable, Sendable {
    var page: Int
    var text: String
    var near: [TextRange]
}

nonisolated struct PdfPlace: Codable, Hashable, Sendable {
    var page: Int
    var x: Double
    var y: Double

    enum CodingKeys: String, CodingKey, CaseIterable { case page, x, y }
}

nonisolated extension PdfPlace {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        page = try wire.decode(Int.self, forKey: .page)
        x = try wire.decode(Double.self, forKey: .x)
        y = try wire.decode(Double.self, forKey: .y)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(page, forKey: .page)
        try wire.encode(x, forKey: .x)
        try wire.encode(y, forKey: .y)
    }
}

nonisolated struct ProjectEdits: Decodable, Hashable, Sendable {
    var edits: DocumentEdits?
    var written: [Written]
    var snapshot: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case edits, written, snapshot }
}

nonisolated extension ProjectEdits {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        edits = try wire.decode(DocumentEdits?.self, forKey: .edits)
        written = try wire.decode([Written].self, forKey: .written)
        snapshot = try wire.decode(String?.self, forKey: .snapshot)
    }
}

nonisolated struct ProjectInfo: Decodable, Hashable, Sendable {
    var id: String
    var name: String
    var mtime: UInt64
    var mainFile: String
    var path: String
    var opened: Bool
    var missing: Bool
    var pdf: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, mtime, mainFile, path, opened, missing, pdf }
}

nonisolated extension ProjectInfo {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(String.self, forKey: .id)
        name = try wire.decode(String.self, forKey: .name)
        mtime = try wire.decode(UInt64.self, forKey: .mtime)
        mainFile = try wire.decode(String.self, forKey: .mainFile)
        path = try wire.decode(String.self, forKey: .path)
        opened = try wire.decode(Bool.self, forKey: .opened)
        missing = try wire.decode(Bool.self, forKey: .missing)
        pdf = try wire.decode(String?.self, forKey: .pdf)
    }
}

nonisolated struct ProjectSettings: Decodable, Hashable, Sendable {
    var mainFile: String
    var engine: Engine
    var stopOnFirstError: Bool
    var shellEscape: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case mainFile, engine, stopOnFirstError, shellEscape }
}

nonisolated extension ProjectSettings {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        mainFile = try wire.decode(String.self, forKey: .mainFile)
        engine = try wire.decode(Engine.self, forKey: .engine)
        stopOnFirstError = try wire.decode(Bool.self, forKey: .stopOnFirstError)
        shellEscape = try wire.decode(Bool.self, forKey: .shellEscape)
    }
}

nonisolated struct ProjectState: Decodable, Hashable, Sendable {
    var name: String
    var root: String
    var settings: ProjectSettings
    var problem: Message?

    enum CodingKeys: String, CodingKey, CaseIterable { case name, root, settings, problem }
}

nonisolated extension ProjectState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        name = try wire.decode(String.self, forKey: .name)
        root = try wire.decode(String.self, forKey: .root)
        settings = try wire.decode(ProjectSettings.self, forKey: .settings)
        problem = try wire.decode(Message?.self, forKey: .problem)
    }
}

nonisolated enum ProjectTemplate: String, Encodable, CaseIterable, Hashable, Sendable {
    case blank, article, report, beamer

    var title: String {
        switch self {
        case .blank: "Blank"
        case .article: "Article"
        case .report: "Report"
        case .beamer: "Presentation"
        }
    }
}

nonisolated struct PutBack: SessionRequest {
    typealias Reply = Done
    static let command = "PutBack"

    var path: String
    var trashed: String
}

nonisolated struct PutBackProject: LibraryRequest {
    typealias Reply = Done
    static let command = "PutBackProject"

    var id: String
    var trashed: String
}

nonisolated struct QuickHelp: Decodable, Hashable, Sendable {
    var title: String
    var detail: String
    var place: FilePlace?

    enum CodingKeys: String, CodingKey, CaseIterable { case title, detail, place }
}

nonisolated extension QuickHelp {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        title = try wire.decode(String.self, forKey: .title)
        detail = try wire.decode(String.self, forKey: .detail)
        place = try wire.decode(FilePlace?.self, forKey: .place)
    }
}

nonisolated struct QuickOpen: SessionRequest {
    typealias Reply = [QuickOpenItem]
    static let command = "QuickOpen"

    var query: String
}

nonisolated struct QuickOpenItem: Decodable, Hashable, Sendable {
    var kind: QuickOpenKind
    var title: String
    var detail: String
    var path: String
    var line: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, title, detail, path, line }
}

nonisolated extension QuickOpenItem {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(QuickOpenKind.self, forKey: .kind)
        title = try wire.decode(String.self, forKey: .title)
        detail = try wire.decode(String.self, forKey: .detail)
        path = try wire.decode(String.self, forKey: .path)
        line = try wire.decode(Int?.self, forKey: .line)
    }
}

nonisolated enum QuickOpenKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case file, heading, label
}

nonisolated enum Reason: String, Decodable, CaseIterable, Hashable, Sendable {
    case replaceAll, rename, addPackage, restore

    var title: String {
        switch self {
        case .replaceAll: "Before Replace All"
        case .rename: "Before Rename"
        case .addPackage: "Before Adding a Package"
        case .restore: "Before Restore"
        }
    }
}

nonisolated struct Reattach: SessionRequest {
    typealias Reply = Done
    static let command = "Reattach"
}

nonisolated struct ReloadProjects: LibraryRequest {
    typealias Reply = Done
    static let command = "ReloadProjects"
}

nonisolated struct ReloadTree: SessionRequest {
    typealias Reply = Done
    static let command = "ReloadTree"
}

nonisolated struct Rename: SessionRequest {
    typealias Reply = RenameResult?
    static let command = "Rename"

    var from: String
    var to: String
}

nonisolated struct RenameProject: LibraryRequest {
    typealias Reply = ProjectInfo
    static let command = "RenameProject"

    var id: String
    var name: String
}

nonisolated struct RenameResult: Decodable, Hashable, Sendable {
    var from: String
    var to: String

    enum CodingKeys: String, CodingKey, CaseIterable { case from, to }
}

nonisolated extension RenameResult {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        from = try wire.decode(String.self, forKey: .from)
        to = try wire.decode(String.self, forKey: .to)
    }
}

nonisolated struct RenameSymbol: SessionRequest {
    typealias Reply = ProjectEdits
    static let command = "RenameSymbol"

    var kind: SymbolKind
    var from: String
    var to: String
}

nonisolated struct Renamed: Decodable, Hashable, Sendable {
    var from: String
    var to: String

    enum CodingKeys: String, CodingKey, CaseIterable { case from, to }
}

nonisolated extension Renamed {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        from = try wire.decode(String.self, forKey: .from)
        to = try wire.decode(String.self, forKey: .to)
    }
}

nonisolated struct RenderMath: SyntaxRequest {
    typealias Reply = MathSvg?
    static let command = "RenderMath"

    var tex: String
    var display: Bool
    var size: Double
}

nonisolated struct Replace: SessionRequest {
    typealias Reply = ProjectEdits
    static let command = "Replace"

    var query: String
    var replacement: String
    var matchCase: Bool
    var wholeWord: Bool
}

nonisolated struct Replied<Payload: Decodable & Sendable>: Decodable, Sendable {
    var id: UInt64
    var answer: Answered<Payload>

    enum CodingKeys: String, CodingKey, CaseIterable { case id, answer }
}

nonisolated extension Replied {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(UInt64.self, forKey: .id)
        answer = try wire.decode(Answered<Payload>.self, forKey: .answer)
    }
}

nonisolated enum Resolution: String, Encodable, CaseIterable, Hashable, Sendable {
    case save, revert, cancel, close
}

nonisolated struct Resolve: SessionRequest {
    typealias Reply = Done
    static let command = "Resolve"

    var path: String
    var answer: Resolution
}

nonisolated struct RestoreVersion: SessionRequest {
    typealias Reply = ProjectEdits
    static let command = "RestoreVersion"

    var id: String
    var paths: [String]?
}

nonisolated struct Resync: LibraryRequest {
    typealias Reply = Done
    static let command = "Resync"
}

nonisolated enum Said<Payload: Decodable & Sendable>: Decodable, Sendable {
    case reply(Replied<Payload>)
    case event(SessionEvent)
    case library(LibrarySection)
    case log(Log)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Said {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "reply": self = .reply(try wire.decode(Replied<Payload>.self, forKey: .value))
        case "event": self = .event(try wire.decode(SessionEvent.self, forKey: .value))
        case "library": self = .library(try wire.decode(LibrarySection.self, forKey: .value))
        case "log": self = .log(try wire.decode(Log.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated struct Save: SessionRequest {
    typealias Reply = Bool
    static let command = "Save"

    var reporting: Bool
}

nonisolated struct SaveVersion: SessionRequest {
    typealias Reply = Snapshot?
    static let command = "SaveVersion"

    var name: String
}

nonisolated struct Search: SessionRequest {
    typealias Reply = [SearchGroup]
    static let command = "Search"

    var query: String
    var matchCase: Bool
    var wholeWord: Bool
}

nonisolated struct SearchGroup: Decodable, Hashable, Sendable {
    var file: String
    var hits: [SearchHit]

    enum CodingKeys: String, CodingKey, CaseIterable { case file, hits }
}

nonisolated extension SearchGroup {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        file = try wire.decode(String.self, forKey: .file)
        hits = try wire.decode([SearchHit].self, forKey: .hits)
    }
}

nonisolated struct SearchHit: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var column: Int
    var length: Int
    var before: String
    var match: String
    var after: String

    enum CodingKeys: String, CodingKey, CaseIterable { case file, line, column, length, before, match, after }
}

nonisolated extension SearchHit {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        file = try wire.decode(String.self, forKey: .file)
        line = try wire.decode(Int.self, forKey: .line)
        column = try wire.decode(Int.self, forKey: .column)
        length = try wire.decode(Int.self, forKey: .length)
        before = try wire.decode(String.self, forKey: .before)
        match = try wire.decode(String.self, forKey: .match)
        after = try wire.decode(String.self, forKey: .after)
    }
}

nonisolated struct SelectsCommand: SourceRequest {
    typealias Reply = Bool
    static let command = "SelectsCommand"

    var selection: TextRange
}

nonisolated struct SessionEvent: Decodable, Hashable, Sendable {
    var session: UInt64
    var event: Event

    enum CodingKeys: String, CodingKey, CaseIterable { case session, event }
}

nonisolated extension SessionEvent {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        session = try wire.decode(UInt64.self, forKey: .session)
        event = try wire.decode(Event.self, forKey: .event)
    }
}

nonisolated enum SessionSection: Decodable, Hashable, Sendable {
    case lifecycle(Lifecycle)
    case project(ProjectState)
    case tree([TreeNode])
    case documents([DocumentState])
    case openFile(OpenFile?)
    case outline(Analysis?)
    case build(BuildState)
    case buildLog(String)
    case shownPdf(ShownPdf)
    case live(LiveState)
    case liveLog(String)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension SessionSection {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "lifecycle": self = .lifecycle(try wire.decode(Lifecycle.self, forKey: .value))
        case "project": self = .project(try wire.decode(ProjectState.self, forKey: .value))
        case "tree": self = .tree(try wire.decode([TreeNode].self, forKey: .value))
        case "documents": self = .documents(try wire.decode([DocumentState].self, forKey: .value))
        case "openFile": self = .openFile(try wire.decode(OpenFile?.self, forKey: .value))
        case "outline": self = .outline(try wire.decode(Analysis?.self, forKey: .value))
        case "build": self = .build(try wire.decode(BuildState.self, forKey: .value))
        case "buildLog": self = .buildLog(try wire.decode(String.self, forKey: .value))
        case "shownPdf": self = .shownPdf(try wire.decode(ShownPdf.self, forKey: .value))
        case "live": self = .live(try wire.decode(LiveState.self, forKey: .value))
        case "liveLog": self = .liveLog(try wire.decode(String.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }
}

nonisolated struct SetHeading: SourceRequest {
    typealias Reply = Insertion
    static let command = "SetHeading"

    var caret: Int
    var command: String
}

nonisolated struct SetOptions: SessionRequest {
    typealias Reply = Done
    static let command = "SetOptions"

    var autoCompile: Bool
}

nonisolated struct SetSettings: SessionRequest {
    typealias Reply = Done
    static let command = "SetSettings"

    var patch: SettingsPatch
}

nonisolated struct SetTexDir: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "SetTexDir"

    var dir: String?
}

nonisolated struct SetTexpressoDir: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "SetTexpressoDir"

    var dir: String?
}

nonisolated struct SetUiState: SessionRequest {
    typealias Reply = Done
    static let command = "SetUiState"

    var patch: UiPatch
}

nonisolated struct SettingsPatch: Encodable, Hashable, Sendable {
    var mainFile: String?
    var engine: Engine?
    var stopOnFirstError: Bool?
    var shellEscape: Bool?
}

nonisolated enum Severity: String, Decodable, CaseIterable, Hashable, Sendable {
    case error, warning
}

nonisolated struct ShownPdf: Decodable, Hashable, Sendable {
    var path: String?
    var version: UInt64
    var live: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case path, version, live }
}

nonisolated extension ShownPdf {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String?.self, forKey: .path)
        version = try wire.decode(UInt64.self, forKey: .version)
        live = try wire.decode(Bool.self, forKey: .live)
    }
}

nonisolated struct Snapshot: Decodable, Hashable, Sendable {
    var id: String
    var time: Int
    var name: String?
    var reason: Reason?
    var changed: [ChangedFile]

    enum CodingKeys: String, CodingKey, CaseIterable { case id, time, name, reason, changed }
}

nonisolated extension Snapshot {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(String.self, forKey: .id)
        time = try wire.decode(Int.self, forKey: .time)
        name = try wire.decode(String?.self, forKey: .name)
        reason = try wire.decode(Reason?.self, forKey: .reason)
        changed = try wire.decode([ChangedFile].self, forKey: .changed)
    }
}

nonisolated struct SnippetField: Codable, Hashable, Sendable {
    var start: Int
    var length: Int
    var index: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case start, length, index }
}

nonisolated extension SnippetField {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        start = try wire.decode(Int.self, forKey: .start)
        length = try wire.decode(Int.self, forKey: .length)
        index = try wire.decode(Int.self, forKey: .index)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(start, forKey: .start)
        try wire.encode(length, forKey: .length)
        try wire.encode(index, forKey: .index)
    }
}

nonisolated struct StartLive: SessionRequest {
    typealias Reply = Done
    static let command = "StartLive"
}

nonisolated struct StartSnippet: SourceRequest {
    typealias Reply = TextRange?
    static let command = "StartSnippet"

    var fields: [SnippetField]
    var at: Int
}

nonisolated struct StopCompile: SessionRequest {
    typealias Reply = Done
    static let command = "StopCompile"
}

nonisolated struct StopLive: SessionRequest {
    typealias Reply = Done
    static let command = "StopLive"
}

nonisolated struct Stopped: Decodable, Hashable, Sendable {
    var unsaved: [String]

    enum CodingKeys: String, CodingKey, CaseIterable { case unsaved }
}

nonisolated extension Stopped {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        unsaved = try wire.decode([String].self, forKey: .unsaved)
    }
}

nonisolated struct StylesAt: SourceRequest {
    typealias Reply = TextStyles
    static let command = "StylesAt"

    var selection: TextRange
}

nonisolated struct Symbol: Decodable, Hashable, Sendable {
    var glyph: String
    var command: String

    enum CodingKeys: String, CodingKey, CaseIterable { case glyph, command }
}

nonisolated extension Symbol {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        glyph = try wire.decode(String.self, forKey: .glyph)
        command = try wire.decode(String.self, forKey: .command)
    }
}

nonisolated struct SymbolAt: SourceRequest {
    typealias Reply = SymbolName?
    static let command = "SymbolAt"

    var at: Int
}

nonisolated struct SymbolGroup: Decodable, Hashable, Sendable {
    var title: String
    var symbols: [Symbol]

    enum CodingKeys: String, CodingKey, CaseIterable { case title, symbols }
}

nonisolated extension SymbolGroup {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        title = try wire.decode(String.self, forKey: .title)
        symbols = try wire.decode([Symbol].self, forKey: .symbols)
    }
}

nonisolated enum SymbolKind: String, Codable, CaseIterable, Hashable, Sendable {
    case command, environment, label, citation, entryType, file

    var title: String {
        switch self {
        case .command: "Command"
        case .environment: "Environment"
        case .label: "Label"
        case .citation: "Citation"
        case .entryType: "Entry Type"
        case .file: "File"
        }
    }
}

nonisolated struct SymbolName: Decodable, Hashable, Sendable {
    var kind: SymbolKind
    var name: String

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, name }
}

nonisolated extension SymbolName {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(SymbolKind.self, forKey: .kind)
        name = try wire.decode(String.self, forKey: .name)
    }
}

nonisolated struct SynctexForward: SessionRequest {
    typealias Reply = ForwardLoc
    static let command = "SynctexForward"

    var file: String
    var line: Int
}

nonisolated struct SynctexInverse: SessionRequest {
    typealias Reply = InverseLoc
    static let command = "SynctexInverse"

    var page: Double
    var x: Double
    var y: Double
    var click: PageClick?
}

nonisolated struct SynctexMatch: SessionRequest {
    typealias Reply = PdfHit?
    static let command = "SynctexMatch"

    var file: String
    var line: Int
    var column: Int
    var pages: [PdfPage]
}

nonisolated struct Tabbing: Decodable, Hashable, Sendable {
    var field: TextRange?
    var edits: [TextEdit]

    enum CodingKeys: String, CodingKey, CaseIterable { case field, edits }
}

nonisolated extension Tabbing {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        field = try wire.decode(TextRange?.self, forKey: .field)
        edits = try wire.decode([TextEdit].self, forKey: .edits)
    }
}

nonisolated struct Template: Decodable, Hashable, Sendable {
    var title: String
    var body: String
    var symbol: String?
    var inline: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case title, body, symbol, inline }
}

nonisolated extension Template {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        title = try wire.decode(String.self, forKey: .title)
        body = try wire.decode(String.self, forKey: .body)
        symbol = try wire.decodeIfPresent(String.self, forKey: .symbol)
        inline = try wire.decode(Bool.self, forKey: .inline)
    }
}

nonisolated struct Templates: Decodable, Hashable, Sendable {
    var math: [Template]
    var insert: [Template]
    var list: [Template]
    var references: [Template]

    enum CodingKeys: String, CodingKey, CaseIterable { case math, insert, list, references }
}

nonisolated extension Templates {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        math = try wire.decode([Template].self, forKey: .math)
        insert = try wire.decode([Template].self, forKey: .insert)
        list = try wire.decode([Template].self, forKey: .list)
        references = try wire.decode([Template].self, forKey: .references)
    }
}

nonisolated struct TexStatus: Decodable, Hashable, Sendable {
    var available: Bool
    var latexmkVersion: String?
    var texDir: String?
    var found: String?
    var texpresso: String?
    var texpressoDir: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case available, latexmkVersion, texDir, found, texpresso, texpressoDir }
}

nonisolated extension TexStatus {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        available = try wire.decode(Bool.self, forKey: .available)
        latexmkVersion = try wire.decode(String?.self, forKey: .latexmkVersion)
        texDir = try wire.decode(String?.self, forKey: .texDir)
        found = try wire.decode(String?.self, forKey: .found)
        texpresso = try wire.decode(String?.self, forKey: .texpresso)
        texpressoDir = try wire.decode(String?.self, forKey: .texpressoDir)
    }
}

nonisolated struct TextEdit: Codable, Hashable, Sendable {
    var start: Int
    var length: Int
    var text: String

    enum CodingKeys: String, CodingKey, CaseIterable { case start, length, text }
}

nonisolated extension TextEdit {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        start = try wire.decode(Int.self, forKey: .start)
        length = try wire.decode(Int.self, forKey: .length)
        text = try wire.decode(String.self, forKey: .text)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(start, forKey: .start)
        try wire.encode(length, forKey: .length)
        try wire.encode(text, forKey: .text)
    }
}

nonisolated struct TextRange: Codable, Hashable, Sendable {
    var start: Int
    var length: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case start, length }
}

nonisolated extension TextRange {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        start = try wire.decode(Int.self, forKey: .start)
        length = try wire.decode(Int.self, forKey: .length)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(start, forKey: .start)
        try wire.encode(length, forKey: .length)
    }
}

nonisolated enum TextStyle: String, Encodable, CaseIterable, Hashable, Sendable {
    case bold, italic, underline
}

nonisolated struct TextStyles: Decodable, Hashable, Sendable {
    var bold: [TextEdit]?
    var italic: [TextEdit]?
    var underline: [TextEdit]?

    enum CodingKeys: String, CodingKey, CaseIterable { case bold, italic, underline }
}

nonisolated extension TextStyles {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        bold = try wire.decode([TextEdit]?.self, forKey: .bold)
        italic = try wire.decode([TextEdit]?.self, forKey: .italic)
        underline = try wire.decode([TextEdit]?.self, forKey: .underline)
    }
}

nonisolated struct ToggleComment: SourceRequest {
    typealias Reply = [TextEdit]
    static let command = "ToggleComment"

    var selections: [TextRange]
}

nonisolated struct ToggleStyle: SourceRequest {
    typealias Reply = Change
    static let command = "ToggleStyle"

    var selections: [TextRange]
    var style: TextStyle
}

nonisolated struct Trash: SessionRequest {
    typealias Reply = String?
    static let command = "Trash"

    var path: String
}

nonisolated struct TrashProject: LibraryRequest {
    typealias Reply = String
    static let command = "TrashProject"

    var id: String
}

nonisolated struct TreeNode: Decodable, Hashable, Sendable {
    var name: String
    var path: String
    var kind: FileKind?
    var children: [TreeNode]?
    var main: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case name, path, kind, children, main }
}

nonisolated extension TreeNode {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        name = try wire.decode(String.self, forKey: .name)
        path = try wire.decode(String.self, forKey: .path)
        kind = try wire.decodeIfPresent(FileKind.self, forKey: .kind)
        children = try wire.decodeIfPresent([TreeNode].self, forKey: .children)
        main = try wire.decode(Bool.self, forKey: .main)
    }
}

nonisolated struct TypeText: SourceRequest {
    typealias Reply = Keystroke
    static let command = "TypeText"

    var selection: TextRange
    var text: String
    var autoPair: Bool
}

nonisolated struct UiPatch: Encodable, Hashable, Sendable {
    var expandedFolders: [String]?
    var foldedHeadings: [String]?
    var place: UiPlace?
}

nonisolated struct UiPlace: Encodable, Hashable, Sendable {
    var file: String?
    var line: Int?
    var zoom: Zoom?
    var pdfPlace: PdfPlace?
}

nonisolated struct UiState: Decodable, Hashable, Sendable {
    var expandedFolders: [String]
    var foldedHeadings: [String]
    var file: String?
    var line: Int?
    var zoom: Zoom?
    var pdfPlace: PdfPlace?

    enum CodingKeys: String, CodingKey, CaseIterable { case expandedFolders, foldedHeadings, file, line, zoom, pdfPlace }
}

nonisolated extension UiState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        expandedFolders = try wire.decode([String].self, forKey: .expandedFolders)
        foldedHeadings = try wire.decode([String].self, forKey: .foldedHeadings)
        file = try wire.decode(String?.self, forKey: .file)
        line = try wire.decode(Int?.self, forKey: .line)
        zoom = try wire.decode(Zoom?.self, forKey: .zoom)
        pdfPlace = try wire.decode(PdfPlace?.self, forKey: .pdfPlace)
    }
}

nonisolated struct Usages: Decodable, Hashable, Sendable {
    var name: String
    var groups: [SearchGroup]

    enum CodingKeys: String, CodingKey, CaseIterable { case name, groups }
}

nonisolated extension Usages {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        name = try wire.decode(String.self, forKey: .name)
        groups = try wire.decode([SearchGroup].self, forKey: .groups)
    }
}

nonisolated struct Words: SourceRequest {
    typealias Reply = Int
    static let command = "Words"

    var selection: TextRange
}

nonisolated struct Wrap: SourceRequest {
    typealias Reply = Change
    static let command = "Wrap"

    var selections: [TextRange]
    var template: String
}

nonisolated struct Written: Decodable, Hashable, Sendable {
    var file: String
    var count: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case file, count }
}

nonisolated extension Written {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        file = try wire.decode(String.self, forKey: .file)
        count = try wire.decode(Int.self, forKey: .count)
    }
}

nonisolated enum Zoom: Codable, Hashable, Sendable {
    case fitWidth
    case fitPage
    case scale(Double)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Zoom {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "fitWidth": self = .fitWidth
        case "fitPage": self = .fitPage
        case "scale": self = .scale(try wire.decode(Double.self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fitWidth: try wire.encode("fitWidth", forKey: .type)
        case .fitPage: try wire.encode("fitPage", forKey: .type)
        case .scale(let value):
            try wire.encode("scale", forKey: .type)
            try wire.encode(value, forKey: .value)
        }
    }
}

@Observable
final class SessionStore {
    private(set) var lifecycle: Lifecycle?
    private(set) var project: ProjectState?
    private(set) var tree: [TreeNode] = []
    private(set) var documents: [DocumentState] = []
    private(set) var openFile: OpenFile?
    private(set) var outline: Analysis?
    private(set) var build: BuildState?
    private(set) var buildLog: String?
    private(set) var shownPdf: ShownPdf?
    private(set) var live: LiveState?
    private(set) var liveLog: String?

    func apply(_ section: SessionSection) {
        switch section {
        case .lifecycle(let value): self.lifecycle = value
        case .project(let value): self.project = value
        case .tree(let value): self.tree = value
        case .documents(let value): self.documents = value
        case .openFile(let value): self.openFile = value
        case .outline(let value): self.outline = value
        case .build(let value): self.build = value
        case .buildLog(let value): self.buildLog = value
        case .shownPdf(let value): self.shownPdf = value
        case .live(let value): self.live = value
        case .liveLog(let value): self.liveLog = value
        }
    }
}

@Observable
final class LibraryStore {
    private(set) var projects: [ProjectInfo] = []
    private(set) var tex: TexStatus?

    func apply(_ section: LibrarySection) {
        switch section {
        case .projects(let value): self.projects = value
        case .tex(let value): self.tex = value
        }
    }
}
