import Foundation
import os
import TeXLocalCore

/// The editor's text as texlocal-syntax's `SourceDocument` mirrors it, and what it answers about it: highlighting,
/// completion, the editing commands, and typing's brackets, indentation and snippet fields, kept between keys.
final class SourceDocument {
    private let raw: OpaquePointer

    /// Text goes by its UTF-8 byte count: a C string would end at a U+0000 the editor keeps.
    init(text: String) {
        var text = text
        raw = text.withUTF8 { tl_source_new($0.baseAddress, $0.count) }
    }

    private init(raw: OpaquePointer) {
        self.raw = raw
    }

    /// The document a project session has open at `path`: each edit is the session's, which saves and previews it.
    convenience init?(session: UInt64, path: String) {
        guard let raw = Core.shared.source(session: session, path: path) else { return nil }
        self.init(raw: raw)
    }

    isolated deinit {
        tl_source_free(raw)
    }

    func edit(_ range: NSRange, with text: String) {
        var text = text
        text.withUTF8 { tl_source_edit(raw, UInt32(range.location), UInt32(range.length), $0.baseAddress, $0.count) }
    }

    /// The editor shows `text` whole, as the session's `document_reload` gave it: not an edit to save.
    func reload(_ text: String) {
        var text = text
        text.withUTF8 { tl_source_reload(raw, $0.baseAddress, $0.count) }
    }

    func line(at offset: Int) -> Int {
        Int(tl_source_line_at(raw, UInt32(offset)))
    }

    func lineStart(_ line: Int) -> Int {
        Int(tl_source_line_start(raw, UInt32(max(1, line))))
    }

    var lineCount: Int {
        Int(tl_source_line_count(raw))
    }

    func highlights(in range: NSRange) -> [(range: NSRange, kind: HighlightKind)] {
        var count = 0
        guard let runs = tl_source_highlights(raw, UInt32(range.location), UInt32(range.length), &count) else { return [] }
        defer { tl_source_free_runs(runs, count) }
        return stride(from: 0, to: count, by: 3).compactMap { i in
            HighlightKind(rawValue: runs[i + 2]).map { (NSRange(location: Int(runs[i]), length: Int(runs[i + 1])), $0) }
        }
    }

    /// Each from its start, however far before the range.
    func notProse(in range: NSRange) -> [NSRange] {
        let ranges: [SourceRange] = call("not_prose", ["selection": Self.json(range)]) ?? []
        return ranges.map(\.range)
    }

    func completions(caret: Int, explicit: Bool) -> Completions? {
        call("completions", ["caret": caret, "explicit": explicit])
    }

    func toggleComment(_ selections: [NSRange]) -> [TextEdit] {
        call("toggle_comment", ["selections": selections.map(Self.json)]) ?? []
    }

    func indent(_ selections: [NSRange], more: Bool) -> [TextEdit] {
        call("indent", ["selections": selections.map(Self.json), "more": more]) ?? []
    }

    func setHeading(caret: Int, command: String) -> Insertion? {
        call("set_heading", ["caret": caret, "command": command])
    }

    func insertBlock(_ id: String, replacing selection: NSRange) -> Insertion? {
        call("insert_block", ["id": id, "selection": Self.json(selection)])
    }

    func insertSymbol(_ command: String, replacing selection: NSRange) -> Insertion? {
        call("insert_symbol", ["command": command, "selection": Self.json(selection)])
    }

    func textStyles(_ selection: NSRange) -> TextStyles {
        call("text_styles", ["selection": Self.json(selection)]) ?? TextStyles()
    }

    func mathAt(caret: Int) -> MathPreview? {
        call("math_at", ["caret": caret])
    }

    var text: String {
        call("text", [:]) ?? ""
    }

    // MARK: typing

    /// A character typed in place of the selection.
    func type(_ text: String, replacing selection: NSRange, autoPair: Bool) -> Keystroke {
        call("type", ["selection": Self.json(selection), "text": text, "autoPair": autoPair]) ?? Keystroke()
    }

    func deleteBackward(_ selection: NSRange, autoPair: Bool) -> Keystroke {
        call("delete_backward", ["selection": Self.json(selection), "autoPair": autoPair]) ?? Keystroke()
    }

    func insertNewline(_ selection: NSRange) -> Keystroke {
        call("insert_newline", ["selection": Self.json(selection)]) ?? Keystroke()
    }

    /// Where the bracket at `at` is matched.
    func partner(of at: Int) -> Int? {
        call("partner", ["at": at])
    }

    /// The storage replaced `old` with text `delta` units longer; `changing` is what the view said it would change.
    func follow(_ old: NSRange, delta: Int, changing: NSRange?, mirroring: Bool) {
        var args: [String: Any] = ["old": Self.json(old), "delta": delta, "mirroring": mirroring]
        if let changing { args["changing"] = Self.json(changing) }
        perform("follow", args)
    }

    /// The view's first selection moved.
    func select(_ selection: NSRange, mirroring: Bool) {
        perform("select", ["selection": Self.json(selection), "mirroring": mirroring])
    }

    /// A completion's or block's fields, put in at `at`: the first field's range, to select.
    func startSnippet(_ fields: [SnippetField], at: Int) -> NSRange? {
        let fields = fields.map { ["start": $0.start, "length": $0.length, "index": $0.index] }
        let first: SourceRange? = call("start_snippet", ["fields": fields, "at": at])
        return first?.range
    }

    /// Whether there was a snippet to end.
    func endSnippet() -> Bool {
        call("end_snippet", [:]) ?? false
    }

    /// Tab (1) or Shift-Tab (-1): a snippet's next field to select, or the lines' indentation.
    func tab(_ selections: [NSRange], step: Int) -> Tabbing {
        call("tab", ["selections": selections.map(Self.json), "step": step]) ?? Tabbing()
    }

    /// What's typed in a snippet's field, for its other places: from the last.
    func mirrorSnippet() -> [TextEdit] {
        call("mirror_snippet", [:]) ?? []
    }

    /// Nil when a line has nowhere to go.
    func moveLines(_ selections: [NSRange], up: Bool) -> Change? {
        call("move_lines", ["selections": selections.map(Self.json), "up": up])
    }

    func toggle(_ style: TextStyle, _ selections: [NSRange]) -> Change? {
        call("toggle_style", ["selections": selections.map(Self.json), "style": style.rawValue])
    }

    /// The selection round a template's "$0".
    func wrap(_ selections: [NSRange], in template: String) -> Change? {
        call("wrap", ["selections": selections.map(Self.json), "template": template])
    }

    func map(_ selections: [NSRange], through edits: [TextEdit]) -> [NSRange] {
        let edits = edits.map { ["start": $0.start, "length": $0.length, "text": $0.text] as [String: Any] }
        let mapped: [SourceRange]? = call("map_selections", ["edits": edits, "selections": selections.map(Self.json)])
        return mapped?.map(\.range) ?? selections
    }

    // MARK: calls

    private static func json(_ range: NSRange) -> [String: Int] {
        ["start": range.location, "length": range.length]
    }

    private func send(_ command: String, _ args: [String: Any]) -> UnsafeMutablePointer<CChar>? {
        guard let json = try? JSONSerialization.data(withJSONObject: args) else { return nil }
        return tl_source_call(raw, command, String(decoding: json, as: UTF8.self))
    }

    private func call<T: Decodable>(_ command: String, _ args: [String: Any]) -> T? {
        Syntax.decode(command, send(command, args))
    }

    /// For a command that answers null.
    private func perform(_ command: String, _ args: [String: Any]) {
        guard let out = send(command, args) else { return Syntax.log.error("\(command, privacy: .public): no answer") }
        tl_free(out)
    }
}

/// texlocal-syntax's commands that need no document (`tl_syntax_call`): the themes' colours, the menus' catalogue,
/// a class's headings, and maths as SVG. On any thread.
nonisolated enum Syntax {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "source")

    static func call<T: Decodable>(_ command: String, _ args: [String: Any]) -> T? {
        guard let json = try? JSONSerialization.data(withJSONObject: args) else {
            log.error("\(command, privacy: .public): arguments that aren't JSON")
            return nil
        }
        return decode(command, tl_syntax_call(command, String(decoding: json, as: UTF8.self)))
    }

    /// Nil for a null answer, which some commands give for none, and frees `out`. No answer, or one in another shape than
    /// was asked for, is a fault of the app's own or the core's, logged as Core logs one.
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

    /// Maths (`math_svg`) or a symbol (`glyph_svg`) as the core draws it, or why it can't.
    nonisolated struct Drawing: Decodable, Sendable {
        var svg: String?
        var width: Double?
        var height: Double?
        var error: String?
    }
}

enum HighlightKind: UInt32, CaseIterable {
    case command, argument, mathDelimiter, mathIdentifier, number, comment, invalid, stringLiteral, builtin
}

nonisolated struct SourceRange: Decodable, Equatable {
    var start: Int
    var length: Int

    var range: NSRange { NSRange(location: start, length: length) }
}

nonisolated struct TextEdit: Decodable, Equatable {
    var start: Int
    var length: Int
    var text: String

    init(_ range: NSRange, _ text: String) {
        (start, length, self.text) = (range.location, range.length, text)
    }

    var range: NSRange { NSRange(location: start, length: length) }
}

/// Edits, applied from the last as one undo step, and the selections after them.
nonisolated struct Change: Decodable {
    var edits: [TextEdit]
    var selections: [SourceRange]
}

/// What a key does instead of what the view would: an edit, typed as a key types, and where the selection goes.
/// Neither: the view handles the key itself.
nonisolated struct Keystroke: Decodable {
    nonisolated enum Completing: String, Decodable {
        case keep, offer, close
    }

    var edit: TextEdit?
    /// Once the edit is in, if not where the edit leaves it.
    var selection: SourceRange?
    /// A bracket whose partner to show.
    var partner: Int?
    var completions = Completing.keep
}

/// Tab: a snippet's field to select, or without a snippet the lines' indentation.
nonisolated struct Tabbing: Decodable {
    var field: SourceRange?
    var edits: [TextEdit] = []
}

nonisolated enum TextStyle: String {
    case bold, italic, underline
}

nonisolated struct TextStyles: Decodable, Equatable {
    var bold: [TextEdit]?
    var italic: [TextEdit]?
    var underline: [TextEdit]?
}

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

nonisolated struct Completion: Decodable {
    var label: String
    var text: String
    var fields: [SnippetField]
}

nonisolated struct MathPreview: Decodable, Equatable {
    var start: Int
    var tex: String
    var display: Bool
}

nonisolated struct SnippetField: Decodable {
    var start: Int
    var length: Int
    var index: Int
}
