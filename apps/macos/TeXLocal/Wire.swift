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
    var log: String

    enum CodingKeys: String, CodingKey, CaseIterable { case ok, stopped, durationMs, pdf, badBoxes, log }
}

nonisolated extension CompileResult {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        ok = try wire.decode(Bool.self, forKey: .ok)
        stopped = try wire.decode(Bool.self, forKey: .stopped)
        durationMs = try wire.decode(UInt64.self, forKey: .durationMs)
        pdf = try wire.decode(String?.self, forKey: .pdf)
        badBoxes = try wire.decode([LogItem].self, forKey: .badBoxes)
        log = try wire.decode(String.self, forKey: .log)
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
    var message: String

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, message }
}

nonisolated extension CoreError {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(ErrorKind.self, forKey: .kind)
        message = try wire.decode(String.self, forKey: .message)
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

nonisolated struct Deleted: SessionRequest {
    typealias Reply = Done
    static let command = "Deleted"

    var path: String
    var trashed: Bool
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

nonisolated struct DocumentRenamed: Decodable, Hashable, Sendable {
    var from: String
    var to: String

    enum CodingKeys: String, CodingKey, CaseIterable { case from, to }
}

nonisolated extension DocumentRenamed {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        from = try wire.decode(String.self, forKey: .from)
        to = try wire.decode(String.self, forKey: .to)
    }
}

nonisolated struct DocumentState: Decodable, Hashable, Sendable {
    var path: String
    var error: String?
    var held: DiskConflict?

    enum CodingKeys: String, CodingKey, CaseIterable { case path, error, held }
}

nonisolated extension DocumentState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        error = try wire.decode(String?.self, forKey: .error)
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
    case invalid, denied, notFound, conflict, unfit, unavailable, `internal`
}

nonisolated enum Event: Decodable, Hashable, Sendable {
    case section(SessionSection)
    case documentReload(String)
    case documentRenamed(DocumentRenamed)
    case conflict(Conflict)
    case filesChanged([String])
    case buildFinished(BuildFinished)
    case liveAlert
    case livePage(LivePage)
    case liveDocument(LiveDocument)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Event {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "section": self = .section(try wire.decode(SessionSection.self, forKey: .value))
        case "documentReload": self = .documentReload(try wire.decode(String.self, forKey: .value))
        case "documentRenamed": self = .documentRenamed(try wire.decode(DocumentRenamed.self, forKey: .value))
        case "conflict": self = .conflict(try wire.decode(Conflict.self, forKey: .value))
        case "filesChanged": self = .filesChanged(try wire.decode([String].self, forKey: .value))
        case "buildFinished": self = .buildFinished(try wire.decode(BuildFinished.self, forKey: .value))
        case "liveAlert": self = .liveAlert
        case "livePage": self = .livePage(try wire.decode(LivePage.self, forKey: .value))
        case "liveDocument": self = .liveDocument(try wire.decode(LiveDocument.self, forKey: .value))
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
    var title: String
    var help: String
    var confirm: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, help, confirm }
}

nonisolated extension Fix {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(String.self, forKey: .id)
        title = try wire.decode(String.self, forKey: .title)
        help = try wire.decode(String.self, forKey: .help)
        confirm = try wire.decodeIfPresent(String.self, forKey: .confirm)
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

nonisolated enum HighlightKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case command, argument, maths, comment, invalid
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
    var message: String
    var short: String
    var compact: String?
    var tokens: [TextRange]
    var others: [String]
    var index: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case line, error, message, short, compact, tokens, others, index }
}

nonisolated extension IssueLine {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        line = try wire.decode(Int.self, forKey: .line)
        error = try wire.decode(Bool.self, forKey: .error)
        message = try wire.decode(String.self, forKey: .message)
        short = try wire.decode(String.self, forKey: .short)
        compact = try wire.decode(String?.self, forKey: .compact)
        tokens = try wire.decode([TextRange].self, forKey: .tokens)
        others = try wire.decode([String].self, forKey: .others)
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

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension LibrarySection {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "projects": self = .projects(try wire.decode([ProjectInfo].self, forKey: .value))
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
    var complete: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case path, changed, complete }
}

nonisolated extension LiveDocument {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        path = try wire.decode(String.self, forKey: .path)
        changed = try wire.decode([PageRange].self, forKey: .changed)
        complete = try wire.decode(Bool.self, forKey: .complete)
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
    case stopped, starting, running, stopping
}

nonisolated struct LiveState: Decodable, Hashable, Sendable {
    var phase: LivePhase
    var engine: Engine
    var halted: Bool
    var log: String?
    var failure: String?
    var error: String?
    var lines: [String: [IssueLine]]

    enum CodingKeys: String, CodingKey, CaseIterable { case phase, engine, halted, log, failure, error, lines }
}

nonisolated extension LiveState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        phase = try wire.decode(LivePhase.self, forKey: .phase)
        engine = try wire.decode(Engine.self, forKey: .engine)
        halted = try wire.decode(Bool.self, forKey: .halted)
        log = try wire.decode(String?.self, forKey: .log)
        failure = try wire.decode(String?.self, forKey: .failure)
        error = try wire.decode(String?.self, forKey: .error)
        lines = try wire.decode([String: [IssueLine]].self, forKey: .lines)
    }
}

nonisolated struct LiveView: SessionRequest {
    typealias Reply = Done
    static let command = "LiveView"

    var first: Int
    var last: Int
}

nonisolated struct LogItem: Decodable, Hashable, Sendable {
    var kind: Severity
    var file: String?
    var line: Int?
    var message: String
    var explain: String?
    var fix: Fix?

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, file, line, message, explain, fix }
}

nonisolated extension LogItem {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        kind = try wire.decode(Severity.self, forKey: .kind)
        file = try wire.decode(String?.self, forKey: .file)
        line = try wire.decode(Int?.self, forKey: .line)
        message = try wire.decode(String.self, forKey: .message)
        explain = try wire.decodeIfPresent(String.self, forKey: .explain)
        fix = try wire.decodeIfPresent(Fix.self, forKey: .fix)
    }
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

nonisolated struct PrepareDelete: SessionRequest {
    typealias Reply = Bool
    static let command = "PrepareDelete"

    var path: String
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

    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, mtime, mainFile, path, opened, missing }
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
    var problem: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case name, root, settings, problem }
}

nonisolated extension ProjectState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        name = try wire.decode(String.self, forKey: .name)
        root = try wire.decode(String.self, forKey: .root)
        settings = try wire.decode(ProjectSettings.self, forKey: .settings)
        problem = try wire.decode(String?.self, forKey: .problem)
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
    typealias Reply = DocumentEdits?
    static let command = "RestoreVersion"

    var id: String
    var paths: [String]?
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
    case project(ProjectState)
    case tree([TreeNode])
    case documents([DocumentState])
    case openFile(OpenFile?)
    case outline(Analysis?)
    case build(BuildState)
    case shownPdf(ShownPdf)
    case live(LiveState)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension SessionSection {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "project": self = .project(try wire.decode(ProjectState.self, forKey: .value))
        case "tree": self = .tree(try wire.decode([TreeNode].self, forKey: .value))
        case "documents": self = .documents(try wire.decode([DocumentState].self, forKey: .value))
        case "openFile": self = .openFile(try wire.decode(OpenFile?.self, forKey: .value))
        case "outline": self = .outline(try wire.decode(Analysis?.self, forKey: .value))
        case "build": self = .build(try wire.decode(BuildState.self, forKey: .value))
        case "shownPdf": self = .shownPdf(try wire.decode(ShownPdf.self, forKey: .value))
        case "live": self = .live(try wire.decode(LiveState.self, forKey: .value))
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
    var reason: String?
    var changed: [ChangedFile]

    enum CodingKeys: String, CodingKey, CaseIterable { case id, time, name, reason, changed }
}

nonisolated extension Snapshot {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        id = try wire.decode(String.self, forKey: .id)
        time = try wire.decode(Int.self, forKey: .time)
        name = try wire.decode(String?.self, forKey: .name)
        reason = try wire.decode(String?.self, forKey: .reason)
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
    var panel: Bool
}

nonisolated struct UiState: Decodable, Hashable, Sendable {
    var expandedFolders: [String]
    var foldedHeadings: [String]
    var file: String?
    var line: Int?
    var zoom: Zoom?
    var panel: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case expandedFolders, foldedHeadings, file, line, zoom, panel }
}

nonisolated extension UiState {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        expandedFolders = try wire.decode([String].self, forKey: .expandedFolders)
        foldedHeadings = try wire.decode([String].self, forKey: .foldedHeadings)
        file = try wire.decode(String?.self, forKey: .file)
        line = try wire.decode(Int?.self, forKey: .line)
        zoom = try wire.decode(Zoom?.self, forKey: .zoom)
        panel = try wire.decode(Bool.self, forKey: .panel)
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
    private(set) var project: ProjectState?
    private(set) var tree: [TreeNode] = []
    private(set) var documents: [DocumentState] = []
    private(set) var openFile: OpenFile?
    private(set) var outline: Analysis?
    private(set) var build: BuildState?
    private(set) var shownPdf: ShownPdf?
    private(set) var live: LiveState?

    func apply(_ section: SessionSection) {
        switch section {
        case .project(let value): self.project = value
        case .tree(let value): self.tree = value
        case .documents(let value): self.documents = value
        case .openFile(let value): self.openFile = value
        case .outline(let value): self.outline = value
        case .build(let value): self.build = value
        case .shownPdf(let value): self.shownPdf = value
        case .live(let value): self.live = value
        }
    }
}

@Observable
final class LibraryStore {
    private(set) var projects: [ProjectInfo] = []

    func apply(_ section: LibrarySection) {
        switch section {
        case .projects(let value): self.projects = value
        }
    }
}
