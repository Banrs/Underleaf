import Foundation
import TeXLocalCore

/// The core's mirror of the source's text (crates/texlocal-syntax, through
/// texlocal-ffi's `tl_source_*`): the text view tells it every edit and asks
/// it what the LaTeX is. Offsets count UTF-16 units, as NSString does.
final class SourceDocument {
    private let raw: OpaquePointer

    init(text: String) {
        raw = tl_source_new(text)
    }

    isolated deinit {
        tl_source_free(raw)
    }

    func edit(_ range: NSRange, with text: String) {
        tl_source_edit(raw, UInt32(range.location), UInt32(range.length), text)
    }

    /// The line an offset is on, from 1.
    func line(at offset: Int) -> Int {
        Int(tl_source_line_at(raw, UInt32(offset)))
    }

    /// Where a line (from 1) starts; past the last line, the last line's start.
    func lineStart(_ line: Int) -> Int {
        Int(tl_source_line_start(raw, UInt32(max(1, line))))
    }

    var lineCount: Int {
        Int(tl_source_line_count(raw))
    }

    /// The highlighted runs of the lines a range touches.
    func highlights(in range: NSRange) -> [(range: NSRange, kind: HighlightKind)] {
        var count = 0
        guard let runs = tl_source_highlights(raw, UInt32(range.location), UInt32(range.length), &count) else { return [] }
        defer { tl_source_free_runs(runs, count) }
        return stride(from: 0, to: count, by: 3).compactMap { i in
            HighlightKind(rawValue: runs[i + 2]).map { (NSRange(location: Int(runs[i]), length: Int(runs[i + 1])), $0) }
        }
    }

    /// What to offer at the caret, if anything; `explicit` when the user
    /// asked, which offers commands after a bare backslash too.
    func completions(caret: Int, explicit: Bool, symbols: Symbols) -> Completions? {
        call("completions", ["caret": caret, "explicit": explicit, "labels": symbols.labels, "citations": symbols.citations])
    }

    /// "%" comments on or off for the lines the selections touch, in order.
    func toggleComment(_ selections: [NSRange]) -> [TextEdit] {
        call("toggle_comment", ["selections": selections.map(Self.json)]) ?? []
    }

    /// The caret's line as a heading of `command` ("section"), or as text given "".
    func setHeading(caret: Int, command: String) -> Insertion? {
        call("set_heading", ["caret": caret, "command": command])
    }

    /// A block by its id in the core's catalog; nil for an id it hasn't.
    func insertBlock(_ id: String, replacing selection: NSRange) -> Insertion? {
        call("insert_block", ["id": id, "selection": Self.json(selection)])
    }

    /// A maths symbol's command, between dollars outside maths.
    func insertSymbol(_ command: String, replacing selection: NSRange) -> Insertion? {
        call("insert_symbol", ["command": command, "selection": Self.json(selection)])
    }

    /// The maths the caret is in or just after, to preview.
    func mathAt(caret: Int) -> MathPreview? {
        call("math_at", ["caret": caret])
    }

    /// The text as the mirror has it.
    var text: String {
        call("text", [:]) ?? ""
    }

    private static func json(_ range: NSRange) -> [String: Int] {
        ["start": range.location, "length": range.length]
    }

    private func call<T: Decodable>(_ command: String, _ args: [String: Any]) -> T? {
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let out = tl_source_call(raw, command, String(decoding: json, as: UTF8.self)) else { return nil }
        defer { tl_free(out) }
        return try? JSONDecoder().decode(T.self, from: Data(bytes: out, count: strlen(out)))
    }
}

/// What a run of the source is (crates/texlocal-syntax `HighlightKind`, in its order).
enum HighlightKind: UInt32 {
    case command, argument, mathDelimiter, mathIdentifier, number, comment, invalid, stringLiteral, builtin
}

/// Replace `length` units at `start` with `text`.
nonisolated struct TextEdit: Decodable, Equatable {
    var start: Int
    var length: Int
    var text: String

    init(_ range: NSRange, _ text: String) {
        (start, length, self.text) = (range.location, range.length, text)
    }

    var range: NSRange { NSRange(location: start, length: length) }
}

/// An edit and where the caret goes after it.
nonisolated struct Insertion: Decodable {
    var edit: TextEdit
    var caret: Int
}

/// Completions for the text from `start` to the caret, which they replace.
nonisolated struct Completions: Decodable {
    var start: Int
    var items: [Completion]
}

nonisolated struct Completion: Decodable {
    var label: String
    /// What goes in, with its fields' defaults.
    var text: String
    var fields: [SnippetField]
}

/// Maths to preview: where it starts, its TeX as KaTeX reads it, and whether it's displayed.
nonisolated struct MathPreview: Decodable, Equatable {
    var start: Int
    var tex: String
    var display: Bool
}

/// A place to type in a completion's text, from its start. Fields with the
/// same index are one field in several places.
nonisolated struct SnippetField: Decodable {
    var start: Int
    var length: Int
    var index: Int
}
