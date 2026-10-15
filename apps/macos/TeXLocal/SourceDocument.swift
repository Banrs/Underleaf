import Foundation
import os
import TeXLocalCore

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
        let ranges: [[String: Int]] = call("not_prose", ["selection": Self.json(range)]) ?? []
        return ranges.map { NSRange(location: $0["start"] ?? 0, length: $0["length"] ?? 0) }
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

    private static func json(_ range: NSRange) -> [String: Int] {
        ["start": range.location, "length": range.length]
    }

    private func send(_ command: String, _ args: [String: Any]) -> UnsafeMutablePointer<CChar>? {
        guard let json = try? JSONSerialization.data(withJSONObject: args) else { return nil }
        return tl_source_call(raw, command, String(decoding: json, as: UTF8.self))
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "source")

    /// Nil for a null answer, which some commands give for none. No answer, or one in another shape than was asked for, is a fault of the app's own or the core's, logged as Core logs one.
    private func call<T: Decodable>(_ command: String, _ args: [String: Any]) -> T? {
        guard let out = send(command, args) else {
            Self.log.error("\(command, privacy: .public): no answer")
            return nil
        }
        defer { tl_free(out) }
        do {
            return try JSONDecoder().decode(T?.self, from: Data(bytes: out, count: strlen(out)))
        } catch {
            Self.log.error("\(command, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

enum HighlightKind: UInt32 {
    case command, argument, mathDelimiter, mathIdentifier, number, comment, invalid, stringLiteral, builtin
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
