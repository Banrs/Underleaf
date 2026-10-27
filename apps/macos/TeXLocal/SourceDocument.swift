import Foundation
import os
import TeXLocalCore

final class SourceDocument {
    private let raw: OpaquePointer

    init(text: String) {
        var text = text
        raw = text.withUTF8 { tl_source_new($0.baseAddress, $0.count) }
    }

    init?(session: UInt64, path: String) {
        guard let raw = Core.shared.source(session: session, path: path) else { return nil }
        self.raw = raw
    }

    isolated deinit { tl_source_free(raw) }

    func edit(_ range: NSRange, with text: String, changing: NSRange?, mirroring: Bool) -> [TextEdit] {
        var text = text
        let said = TlRange(start: UInt32(changing?.location ?? 0), length: UInt32(changing?.length ?? 0))
        let out = text.withUTF8 { text in
            withUnsafePointer(to: said) { said in
                tl_source_edit(raw, UInt32(range.location), UInt32(range.length), text.baseAddress, text.count,
                               changing == nil ? nil : said, mirroring)
            }
        }
        guard let out else { return [] }
        return Syntax.decode("edit", out) ?? []
    }

    func select(_ selection: NSRange, mirroring: Bool) {
        tl_source_select(raw, UInt32(selection.location), UInt32(selection.length), mirroring)
    }

    @discardableResult func reload(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { tl_source_reload(raw, $0.baseAddress, $0.count) }
    }

    func line(at offset: Int) -> Int { Int(tl_source_line_at(raw, UInt32(offset))) }
    func lineStart(_ line: Int) -> Int { Int(tl_source_line_start(raw, UInt32(max(1, line)))) }
    var lineCount: Int { Int(tl_source_line_count(raw)) }

    func highlights(in range: NSRange) -> [(range: NSRange, kind: HighlightKind)] {
        var count = 0
        guard let runs = tl_source_highlights(raw, UInt32(range.location), UInt32(range.length), &count) else { return [] }
        defer { tl_source_free_runs(runs, count) }
        return stride(from: 0, to: count, by: 3).compactMap { i in
            HighlightKind(rawValue: runs[i + 2]).map { (NSRange(location: Int(runs[i]), length: Int(runs[i + 1])), $0) }
        }
    }

    func codeRanges(in range: NSRange, for checker: Checker) -> [NSRange] {
        (call("code_ranges", ["selection": range.json, "for": checker.rawValue]) as [SourceRange]?)?.map(\.range) ?? []
    }

    nonisolated enum Checker: String { case spelling, writingTools }

    func completions(caret: Int, explicit: Bool) -> Completions? { call("completions", ["caret": caret, "explicit": explicit]) }
    func toggleComment(_ selections: [NSRange]) -> [TextEdit] { call("toggle_comment", ["selections": selections.map(\.json)]) ?? [] }
    func setHeading(caret: Int, command: String) -> Insertion? { call("set_heading", ["caret": caret, "command": command]) }
    func insertBlock(_ id: String, replacing selection: NSRange) -> Insertion? { call("insert_block", ["id": id, "selection": selection.json]) }
    func insertSymbol(_ command: String, replacing selection: NSRange) -> Insertion? {
        call("insert_symbol", ["command": command, "selection": selection.json])
    }
    func textStyles(_ selection: NSRange) -> TextStyles { call("text_styles", ["selection": selection.json]) ?? TextStyles() }
    func mathAt(caret: Int) -> MathPreview? { call("math_at", ["caret": caret]) }
    struct Fold: Decodable, Hashable { let line: Int, end: Int }

    func folds() -> [Fold] { call("folds", [:]) ?? [] }
    func words(in range: NSRange) -> Int { (call("words", range.json) as WordCount?)?.words ?? 0 }
    func definition(at offset: Int) -> Definition? { call("definition", ["at": offset]) }
    var version: Int? { call("version", [:]) }

    var text: String {
        var count = 0
        guard let bytes = tl_source_text(raw, &count) else { return "" }
        defer { tl_source_free_text(bytes, count) }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func type(_ text: String, replacing selection: NSRange, autoPair: Bool) -> Keystroke {
        call("type", ["selection": selection.json, "text": text, "autoPair": autoPair]) ?? Keystroke()
    }

    func deleteBackward(_ selection: NSRange, autoPair: Bool) -> Keystroke {
        call("delete_backward", ["selection": selection.json, "autoPair": autoPair]) ?? Keystroke()
    }

    func insertNewline(_ selection: NSRange) -> Keystroke { call("insert_newline", ["selection": selection.json]) ?? Keystroke() }

    func partner(of at: Int) -> Int? { call("partner", ["at": at]) }

    func startSnippet(_ fields: [SnippetField], at: Int) -> NSRange? {
        let fields = fields.map { ["start": $0.start, "length": $0.length, "index": $0.index] }
        return (call("start_snippet", ["fields": fields, "at": at]) as SourceRange?)?.range
    }

    func endSnippet() -> Bool { call("end_snippet", [:]) ?? false }

    func tab(_ selections: [NSRange], step: Int) -> Tabbing { call("tab", ["selections": selections.map(\.json), "step": step]) ?? Tabbing() }

    func moveLines(_ selections: [NSRange], up: Bool) -> Change? { call("move_lines", ["selections": selections.map(\.json), "up": up]) }

    func duplicateLines(_ selections: [NSRange]) -> Change? { call("duplicate_lines", ["selections": selections.map(\.json)]) }

    func deleteLines(_ selections: [NSRange]) -> Change? { call("delete_lines", ["selections": selections.map(\.json)]) }

    func toggle(_ style: TextStyle, _ selections: [NSRange]) -> Change? {
        call("toggle_style", ["selections": selections.map(\.json), "style": style.rawValue])
    }

    func wrap(_ selections: [NSRange], in template: String) -> Change? {
        call("wrap", ["selections": selections.map(\.json), "template": template])
    }

    func map(_ selections: [NSRange], through edits: [TextEdit]) -> [NSRange] {
        let edits = edits.map { ["start": $0.start, "length": $0.length, "text": $0.text] as [String: Any] }
        let mapped: [SourceRange]? = call("map_selections", ["edits": edits, "selections": selections.map(\.json)])
        return mapped?.map(\.range) ?? selections
    }

    private func call<T: Decodable>(_ command: String, _ args: [String: Any]) -> T? {
        Syntax.decode(command, tl_source_call(raw, command, Syntax.json(args)))
    }
}

private extension NSRange {
    var json: [String: Int] { ["start": location, "length": length] }
}

nonisolated enum Syntax {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "source")

    static func call<T: Decodable>(_ command: String, _ args: [String: Any]) -> T? { decode(command, tl_syntax_call(command, json(args))) }

    static func json(_ args: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self) }

    static func decode<T: Decodable>(_ command: String, _ out: UnsafeMutablePointer<CChar>?) -> T? {
        guard let out else {
            log.error("\(command, privacy: .public): no answer")
            return nil
        }
        defer { tl_free(out) }
        do {
            return try JSONDecoder().decode(T?.self, from: Data(bytes: out, count: strlen(out)))
        } catch {
            log.error("\(command, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated struct Drawing: Decodable, Sendable {
        let svg: String
        let width, height: Double
    }
}

enum HighlightKind: UInt32, CaseIterable {
    case command, argument, maths, comment, invalid
}

nonisolated struct SourceRange: Decodable, Equatable {
    var start, length: Int

    var range: NSRange { NSRange(location: start, length: length) }
}

nonisolated struct TextEdit: Decodable, Equatable {
    var start, length: Int
    var text: String

    init(_ range: NSRange, _ text: String) { (start, length, self.text) = (range.location, range.length, text) }

    var range: NSRange { NSRange(location: start, length: length) }
}

nonisolated struct Change: Decodable {
    var edits: [TextEdit]
    var selections: [SourceRange]
}

nonisolated struct Keystroke: Decodable {
    nonisolated enum Completing: String, Decodable { case keep, offer, close }

    var edit: TextEdit?
    var selection: SourceRange?
    var partner: Int?
    var completions = Completing.keep
}

nonisolated struct Tabbing: Decodable {
    var field: SourceRange?
    var edits: [TextEdit] = []
}

nonisolated enum TextStyle: String { case bold, italic, underline }

nonisolated struct TextStyles: Decodable, Equatable { var bold, italic, underline: [TextEdit]? }

nonisolated struct Insertion: Decodable {
    var edit: TextEdit
    var caret: Int
    var fields: [SnippetField]
}

nonisolated struct Completions: Decodable {
    var start: Int
    var kind: CompletionKind
    var items: [Completion]
}

nonisolated enum CompletionKind: String, Decodable {
    case command, environment, label, citation, entryType, file

    var name: String {
        switch self {
        case .command: String(localized: "Command")
        case .environment: String(localized: "Environment")
        case .label: String(localized: "Label")
        case .citation: String(localized: "Citation")
        case .entryType: String(localized: "Entry Type")
        case .file: String(localized: "File")
        }
    }
}

nonisolated struct Completion: Decodable {
    var label, text: String
    var fields: [SnippetField]
    var detail: String?
}

nonisolated struct Definition: Decodable, Hashable {
    nonisolated struct Place: Decodable, Hashable {
        var file: String
        var line, column, length: Int
    }

    var kind: String
    var name: String
    var places: [Place]
}

private nonisolated struct WordCount: Decodable { var words: Int }

nonisolated struct MathPreview: Decodable, Equatable {
    var start: Int
    var tex: String
    var display: Bool
}

nonisolated struct SnippetField: Decodable { var start, length, index: Int }
