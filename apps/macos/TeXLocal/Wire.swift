import Foundation

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

nonisolated struct CheckTex: LibraryRequest {
    typealias Reply = TexStatus
    static let command = "CheckTex"
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

nonisolated struct CreateProject: LibraryRequest {
    typealias Reply = ProjectInfo
    static let command = "CreateProject"

    var name: String
    var template: ProjectTemplate
    var engine: Engine?
}

nonisolated struct DuplicateProject: LibraryRequest {
    typealias Reply = ProjectInfo
    static let command = "DuplicateProject"

    var id: String
    var name: String
}

nonisolated enum Engine: String, Encodable, CaseIterable, Hashable, Sendable {
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

nonisolated struct ExportZip: LibraryRequest {
    typealias Reply = Done
    static let command = "ExportZip"

    var id: String
    var dest: String
    var forArxiv: Bool
}

nonisolated enum FileKind: String, Decodable, CaseIterable, Hashable, Sendable {
    case tex, bib, image, pdf, text, other
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

nonisolated enum ImportConflict: String, Encodable, CaseIterable, Hashable, Sendable {
    case replace, keepBoth
}

nonisolated struct ImportFiles: LibraryRequest {
    typealias Reply = Imported
    static let command = "ImportFiles"

    var id: String
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

nonisolated struct KillAll: LibraryRequest {
    typealias Reply = Done
    static let command = "KillAll"
}

nonisolated struct ListProjects: LibraryRequest {
    typealias Reply = [ProjectInfo]
    static let command = "ListProjects"
}

nonisolated struct OpenPath: LibraryRequest {
    typealias Reply = Opening
    static let command = "OpenPath"

    var path: String
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

nonisolated struct PageClick: Encodable, Hashable, Sendable {
    var text: String
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

nonisolated struct PdfPath: LibraryRequest {
    typealias Reply = String
    static let command = "PdfPath"

    var id: String
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

nonisolated struct ReadTree: LibraryRequest {
    typealias Reply = [TreeNode]
    static let command = "ReadTree"

    var id: String
}

nonisolated struct RenameProject: LibraryRequest {
    typealias Reply = ProjectInfo
    static let command = "RenameProject"

    var id: String
    var name: String
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

nonisolated struct SetUiState: LibraryRequest {
    typealias Reply = Done
    static let command = "SetUiState"

    var id: String
    var patch: UiPatch
}

nonisolated struct SynctexForward: LibraryRequest {
    typealias Reply = ForwardLoc
    static let command = "SynctexForward"

    var id: String
    var file: String
    var line: Int
    var live: UInt64?
}

nonisolated struct SynctexInverse: LibraryRequest {
    typealias Reply = InverseLoc
    static let command = "SynctexInverse"

    var id: String
    var page: Double
    var x: Double
    var y: Double
    var click: PageClick?
    var live: UInt64?
}

nonisolated struct SynctexMatch: LibraryRequest {
    typealias Reply = PdfHit?
    static let command = "SynctexMatch"

    var id: String
    var file: String
    var line: Int
    var column: Int
    var pages: [PdfPage]
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

nonisolated struct TextRange: Encodable, Hashable, Sendable {
    var start: Int
    var length: Int
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

nonisolated struct UiPatch: Encodable, Hashable, Sendable {
    var expandedFolders: [String]?
    var foldedHeadings: [String]?
    var place: UiPlace?
}

nonisolated struct UiPlace: Encodable, Hashable, Sendable {
    var file: String?
    var line: Int?
    var page: Int?
    var zoom: Zoom?
    var panel: Bool
}

nonisolated enum Zoom: Encodable, Hashable, Sendable {
    case fitWidth
    case fitPage
    case scale(Double)

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension Zoom {
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
