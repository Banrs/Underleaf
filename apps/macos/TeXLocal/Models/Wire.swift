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

nonisolated protocol LibraryRequest: WireRequest {}

nonisolated protocol SessionRequest: WireRequest {}

nonisolated protocol SourceRequest: WireRequest {}

nonisolated protocol SyntaxRequest: WireRequest {}

nonisolated struct AddCitation: SessionRequest {
    typealias Reply = AddedCitation
    static let command = "AddCitation"

    var entry: String
}

nonisolated struct AddedCitation: Decodable, Hashable, Sendable {
    var key: String
    var file: String
    var edits: ProjectEdits?
}

nonisolated struct Analysis: Decodable, Hashable, Sendable {
    var tree: [OutlineNode]
    var words: Int
    var headingStyles: [HeadingStyle]
    var packages: [String]
}

nonisolated enum Answered<Payload: Decodable & Sendable>: Decodable, Sendable {
    case ok(Payload)
    case error(CoreError)

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension Answered {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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

nonisolated struct BadBoxArea: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var tooWide: Double?
    var message: String
    var area: ForwardLoc
    var overrun: Double
}

nonisolated struct BadBoxAreas: SessionRequest {
    typealias Reply = [BadBoxArea]
    static let command = "BadBoxAreas"
}

nonisolated struct BuildFinished: Decodable, Hashable, Sendable {
    var auto: Bool
    var announce: Bool
}

nonisolated struct BuildState: Decodable, Hashable, Sendable {
    var compiling: Bool
    var auto: Bool
    var outdated: Bool
    var result: CompileResult?
    var issues: [LogItem]
    var lines: [String: [IssueLine]]
}

nonisolated struct Change: Decodable, Hashable, Sendable {
    var edits: [TextEdit]
    var selections: [TextRange]
}

nonisolated enum ChangeKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case added, deleted, changed
}

nonisolated struct ChangedFile: Decodable, Hashable, Sendable {
    var path: String
    var change: ChangeKind
}

nonisolated struct CheckTex: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "CheckTex"
}

nonisolated enum Checker: String, Encodable, CaseIterable, Hashable, Sendable {
    case spelling, writingTools
}

nonisolated struct CitationSource: Decodable, Hashable, Sendable {
    var id: String
    var url: String
    var accept: String
}

nonisolated struct Clash: Decodable, Hashable, Sendable {
    var path: String
    var keepBoth: String
}

nonisolated struct Clean: SessionRequest {
    typealias Reply = Done
    static let command = "Clean"
}

nonisolated struct CloseProject: SessionRequest {
    typealias Reply = Bool
    static let command = "CloseProject"

    var discard: Bool?
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
}

nonisolated struct Completions: Decodable, Hashable, Sendable {
    var start: Int
    var kind: SymbolKind
    var items: [Completion]
}

nonisolated struct CoreError: Decodable, Hashable, Sendable {
    var kind: ErrorKind
    var message: Message
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

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension DiffLine {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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
}

nonisolated struct DocumentState: Decodable, Hashable, Sendable {
    var path: String
    var error: Message?
    var conflict: DiskConflict?
    var asking: Bool
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
    case reload(DocumentEdits)
    case renamed(Renamed)
    case filesChanged([String])
    case buildFinished(BuildFinished)
    case liveAlert
    case livePage(LivePage)
    case liveDocument(LiveDocument)
    case liveFollow(ForwardLoc)

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension Event {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "section": self = .section(try wire.decode(SessionSection.self, forKey: .value))
        case "reload": self = .reload(try wire.decode(DocumentEdits.self, forKey: .value))
        case "renamed": self = .renamed(try wire.decode(Renamed.self, forKey: .value))
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
}

nonisolated struct Fixed: Decodable, Hashable, Sendable {
    var edits: DocumentEdits?
}

nonisolated struct Fold: Decodable, Hashable, Sendable {
    var line: Int
    var end: Int
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
}

nonisolated struct HeadingStyle: Decodable, Hashable, Sendable {
    var title: String
    var command: String
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
}

nonisolated struct InstallTex: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "InstallTex"
}

nonisolated struct InverseLoc: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var column: Int?
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
}

nonisolated struct Keystroke: Decodable, Hashable, Sendable {
    var edit: TextEdit?
    var selection: TextRange?
    var partner: Int?
    var completions: Completing
}

nonisolated struct KillAll: LibraryRequest {
    typealias Reply = Done
    static let command = "KillAll"
}

nonisolated enum LibrarySection: Decodable, Hashable, Sendable {
    case projects([ProjectInfo])
    case tex(TexStatus)

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension LibrarySection {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension Lifecycle {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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

nonisolated struct LiveDocument: Decodable, Hashable, Sendable {
    var path: String
    var changed: [PageRange]
}

nonisolated struct LiveLog: SessionRequest {
    typealias Reply = Done
    static let command = "LiveLog"

    var shown: Bool
}

nonisolated struct LivePage: Decodable, Hashable, Sendable {
    var page: Int
    var pdf: Data
}

nonisolated enum LivePhase: String, Decodable, CaseIterable, Hashable, Sendable {
    case stopped, starting, running
}

nonisolated struct LiveState: Decodable, Hashable, Sendable {
    var phase: LivePhase
    var engine: Engine
    var halted: Bool
    var attention: Bool
    var failures: [Message]
    var lines: [String: [IssueLine]]
}

nonisolated struct LiveView: SessionRequest {
    typealias Reply = Done
    static let command = "LiveView"

    var first: Int
    var last: Int
}

nonisolated struct LocateCitation: SyntaxRequest {
    typealias Reply = CitationSource?
    static let command = "LocateCitation"

    var text: String
}

nonisolated struct Log: Decodable, Hashable, Sendable {
    var level: LogLevel
    var text: String
}

nonisolated struct LogItem: Decodable, Hashable, Sendable {
    var kind: Severity
    var file: String?
    var line: Int?
    var message: Message
    var explain: Message?
    var fix: Fix?
    var topic: Topic?
}

nonisolated enum LogKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case error, warning, badBox, info
}

nonisolated struct LogKinds: SyntaxRequest {
    typealias Reply = [LogKind]
    static let command = "LogKinds"

    var log: String
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
}

nonisolated struct MathSvg: Decodable, Hashable, Sendable {
    var svg: String
    var width: Double
    var height: Double
}

nonisolated struct Menus: Decodable, Hashable, Sendable {
    var templates: Templates
    var symbolGroups: [SymbolGroup]
}

nonisolated struct Message: Decodable, Hashable, Sendable {
    var id: MessageID
    var args: [String: String]
    var text: String
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
    case notUtf8Name = "not_utf8_name"
    case notUtf8File = "not_utf8_file"
    case tooLargeToKeep = "too_large_to_keep"
    case renamedSymbolUnfit = "renamed_symbol_unfit"
    case badLabelName = "bad_label_name"
    case badCitationName = "bad_citation_name"
    case labelExists = "label_exists"
    case citationExists = "citation_exists"
    case noBibtex = "no_bibtex"
    case versionNeedsName = "version_needs_name"
    case onlyTextCompared = "only_text_compared"
    case versionGone = "version_gone"
    case badVersionId = "bad_version_id"
    case mainFileMissing = "main_file_missing"
    case mainFileShellName = "main_file_shell_name"
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
    var text: Bool
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
}

nonisolated struct OutlineNode: Decodable, Hashable, Sendable {
    var index: Int
    var heading: Heading
    var foldKey: String
    var children: [OutlineNode]?
}

nonisolated struct PageClick: Encodable, Hashable, Sendable {
    var text: String
    var at: Int
}

nonisolated struct PageRange: Decodable, Hashable, Sendable {
    var first: Int
    var last: Int
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
}

nonisolated struct ProjectEdits: Decodable, Hashable, Sendable {
    var edits: DocumentEdits?
    var written: [Written]
    var snapshot: String?
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
}

nonisolated struct ProjectSettings: Decodable, Hashable, Sendable {
    var mainFile: String
    var engine: Engine
    var stopOnFirstError: Bool
    var shellEscape: Bool
}

nonisolated struct ProjectState: Decodable, Hashable, Sendable {
    var name: String
    var root: String
    var settings: ProjectSettings
    var problem: Message?
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
    var kind: SymbolKind
    var title: String
    var detail: String
    var place: FilePlace?
    var shown: ForwardLoc?
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
}

nonisolated enum QuickOpenKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case file, heading, label
}

nonisolated enum Reason: String, Decodable, CaseIterable, Hashable, Sendable {
    case replaceAll, rename, addPackage, restore, addCitation

    var title: String {
        switch self {
        case .replaceAll: "Before Replace All"
        case .rename: "Before Rename"
        case .addPackage: "Before Adding a Package"
        case .restore: "Before Restore"
        case .addCitation: "Before Adding a Citation"
        }
    }
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

nonisolated enum Said<Payload: Decodable & Sendable>: Decodable, Sendable {
    case reply(Replied<Payload>)
    case event(SessionEvent)
    case library(LibrarySection)
    case log(Log)

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension Said {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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
}

nonisolated struct SearchHit: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var column: Int
    var length: Int
    var before: String
    var match: String
    var after: String
}

nonisolated struct SelectsCommand: SourceRequest {
    typealias Reply = Bool
    static let command = "SelectsCommand"

    var selection: TextRange
}

nonisolated struct SessionEvent: Decodable, Hashable, Sendable {
    var session: UInt64
    var event: Event
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

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension SessionSection {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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
}

nonisolated struct Snapshot: Decodable, Hashable, Sendable {
    var id: String
    var time: Int
    var name: String?
    var reason: Reason?
    var changed: [ChangedFile]
}

nonisolated struct SnippetField: Codable, Hashable, Sendable {
    var start: Int
    var length: Int
    var index: Int
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
}

nonisolated struct StylesAt: SourceRequest {
    typealias Reply = TextStyles
    static let command = "StylesAt"

    var selection: TextRange
}

nonisolated struct Symbol: Decodable, Hashable, Sendable {
    var glyph: String
    var command: String
}

nonisolated struct SymbolAt: SourceRequest {
    typealias Reply = SymbolName?
    static let command = "SymbolAt"

    var at: Int
}

nonisolated struct SymbolGroup: Decodable, Hashable, Sendable {
    var title: String
    var symbols: [Symbol]
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
}

nonisolated struct Tabular: SyntaxRequest {
    typealias Reply = String?
    static let command = "Tabular"

    var cells: String
    var indent: String
    var booktabs: Bool
}

nonisolated struct Template: Decodable, Hashable, Sendable {
    var title: String
    var body: String
    var symbol: String?
    var inline: Bool
}

nonisolated struct Templates: Decodable, Hashable, Sendable {
    var math: [Template]
    var insert: [Template]
    var list: [Template]
    var references: [Template]
}

nonisolated struct TexStatus: Decodable, Hashable, Sendable {
    var available: Bool
    var latexmkVersion: String?
    var texDir: String?
    var found: String?
    var texpresso: String?
    var texpressoDir: String?
}

nonisolated struct TextEdit: Codable, Hashable, Sendable {
    var start: Int
    var length: Int
    var text: String
}

nonisolated struct TextRange: Codable, Hashable, Sendable {
    var start: Int
    var length: Int
}

nonisolated enum TextStyle: String, Encodable, CaseIterable, Hashable, Sendable {
    case bold, italic, underline
}

nonisolated struct TextStyles: Decodable, Hashable, Sendable {
    var bold: [TextEdit]?
    var italic: [TextEdit]?
    var underline: [TextEdit]?
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

nonisolated enum Topic: String, Decodable, CaseIterable, Hashable, Sendable {
    case badBox, undefinedReference
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
}

nonisolated struct Usages: Decodable, Hashable, Sendable {
    var name: String
    var groups: [SearchGroup]
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
}

nonisolated enum Zoom: Codable, Hashable, Sendable {
    case fitWidth
    case fitPage
    case scale(Double)

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension Zoom {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
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
