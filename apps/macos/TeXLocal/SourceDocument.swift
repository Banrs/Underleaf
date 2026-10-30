import Foundation
import os
import TeXLocalCore

final class SourceDocument {
    private let raw: OpaquePointer
    var shown: () -> String? = { nil }

    init(text: String) {
        var text = text
        raw = text.withUTF8 { tl_source_new($0.baseAddress, $0.count) }
    }

    init?(session: SessionClient, path: String) {
        guard let raw = session.source(path) else { return nil }
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
        return answered("Edit", out) ?? []
    }

    func select(_ selection: NSRange, mirroring: Bool) {
        tl_source_select(raw, UInt32(selection.location), UInt32(selection.length), mirroring)
    }

    private func restore() {
        guard var text = shown() else { return }
        text.withUTF8 { tl_source_restore(raw, $0.baseAddress, $0.count) }
    }

    var editable: Bool { tl_source_editable(raw) }

    var version: UInt64? {
        var version: UInt64 = 0
        return tl_source_version(raw, &version) ? version : nil
    }

    func line(at offset: Int) -> Int { Int(tl_source_line_at(raw, UInt32(offset))) }
    func lineStart(_ line: Int) -> Int { Int(tl_source_line_start(raw, UInt32(max(1, line)))) }
    var lineCount: Int { Int(tl_source_line_count(raw)) }

    func highlights(in range: NSRange) -> [(range: NSRange, kind: HighlightKind)] {
        var count = 0
        guard let runs = tl_source_highlights(raw, UInt32(range.location), UInt32(range.length), &count) else { return [] }
        defer { tl_source_free_runs(runs, count) }
        let kinds = HighlightKind.allCases
        return stride(from: 0, to: count, by: 3).compactMap { i in
            let kind = Int(runs[i + 2])
            return kinds.indices.contains(kind) ? (NSRange(location: Int(runs[i]), length: Int(runs[i + 1])), kinds[kind]) : nil
        }
    }

    func codeRanges(in range: NSRange, for checker: Checker) -> [NSRange] {
        (call(CodeRanges(selection: TextRange(range), checker: checker)) ?? []).map(\.range)
    }

    func completions(caret: Int, explicit: Bool) -> Completions? { call(Complete(caret: caret, explicit: explicit)) ?? nil }
    func toggleComment(_ selections: [NSRange]) -> [TextEdit] { call(ToggleComment(selections: selections.map(TextRange.init))) ?? [] }
    func setHeading(caret: Int, command: String) -> Insertion? { call(SetHeading(caret: caret, command: command)) }
    func insertBlock(_ id: String, replacing selection: NSRange) -> Insertion? {
        call(InsertBlock(id: id, selection: TextRange(selection))) ?? nil
    }
    func insertSymbol(_ command: String, replacing selection: NSRange) -> Insertion? {
        call(InsertSymbol(command: command, selection: TextRange(selection)))
    }
    func textStyles(_ selection: NSRange) -> TextStyles { call(StylesAt(selection: TextRange(selection))) ?? TextStyles() }
    func mathAt(caret: Int) -> MathPreview? { call(MathAt(caret: caret)) ?? nil }
    func folds() -> [Fold] { call(Folds()) ?? [] }
    func words(in range: NSRange) -> Int { call(Words(selection: TextRange(range))) ?? 0 }
    func definition(at offset: Int) -> Definition? { call(DefinitionAt(at: offset)) ?? nil }
    func symbol(at offset: Int) -> SymbolName? { call(SymbolAt(at: offset)) ?? nil }

    var text: String {
        var count = 0
        guard let bytes = tl_source_text(raw, &count) else { return "" }
        defer { tl_source_free_text(bytes, count) }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func type(_ text: String, replacing selection: NSRange, autoPair: Bool) -> Keystroke {
        call(TypeText(selection: TextRange(selection), text: text, autoPair: autoPair)) ?? Keystroke(completions: .keep)
    }

    func deleteBackward(_ selection: NSRange, autoPair: Bool) -> Keystroke {
        call(DeleteBackward(selection: TextRange(selection), autoPair: autoPair)) ?? Keystroke(completions: .keep)
    }

    func insertNewline(_ selection: NSRange) -> Keystroke {
        call(InsertNewline(selection: TextRange(selection))) ?? Keystroke(completions: .keep)
    }

    func partner(of at: Int) -> Int? { call(Partner(at: at)) ?? nil }

    func startSnippet(_ fields: [SnippetField], at: Int) -> NSRange? { (call(StartSnippet(fields: fields, at: at)) ?? nil)?.range }

    func endSnippet() -> Bool { call(EndSnippet()) ?? false }

    func tab(_ selections: [NSRange], step: Int) -> Tabbing {
        call(InsertTab(selections: selections.map(TextRange.init), step: step)) ?? Tabbing(edits: [])
    }

    func moveLines(_ selections: [NSRange], up: Bool) -> Change? { call(MoveLines(selections: selections.map(TextRange.init), up: up)) ?? nil }

    func duplicateLines(_ selections: [NSRange]) -> Change? { call(DuplicateLines(selections: selections.map(TextRange.init))) }

    func deleteLines(_ selections: [NSRange]) -> Change? { call(DeleteLines(selections: selections.map(TextRange.init))) }

    func toggle(_ style: TextStyle, _ selections: [NSRange]) -> Change? {
        call(ToggleStyle(selections: selections.map(TextRange.init), style: style))
    }

    func wrap(_ selections: [NSRange], in template: String) -> Change? {
        call(Wrap(selections: selections.map(TextRange.init), template: template))
    }

    func map(_ selections: [NSRange], through edits: [TextEdit]) -> [NSRange] {
        call(MapSelections(edits: edits, selections: selections.map(TextRange.init)))?.map(\.range) ?? selections
    }

    private func call<R: SourceRequest>(_ request: R) -> R.Reply? {
        Syntax.json(request).flatMap { answered(R.command, tl_source_call(raw, R.command, $0)) }
    }

    private func answered<T: Decodable>(_ command: String, _ out: UnsafeMutablePointer<CChar>) -> T? {
        let answer: T? = Syntax.answer(command, out)
        if answer == nil { restore() }
        return answer
    }
}

nonisolated enum Syntax {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "source")

    static func call<R: SyntaxRequest>(_ request: R) -> R.Reply? { json(request).flatMap { answer(R.command, tl_syntax_call(R.command, $0)) } }

    static func json<R: WireRequest>(_ request: R) -> String? {
        do {
            return String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        } catch {
            log.error("\(R.command, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func answer<T: Decodable>(_ command: String, _ out: UnsafeMutablePointer<CChar>) -> T? {
        defer { tl_free(out) }
        do {
            return try Core.decoded(command, Data(bytes: out, count: strlen(out))) as T
        } catch {
            log.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

nonisolated extension TextEdit {
    init(_ range: NSRange, _ text: String) { self.init(start: range.location, length: range.length, text: text) }

    var range: NSRange { NSRange(location: start, length: length) }
}

nonisolated extension TextRange {
    init(_ range: NSRange) { self.init(start: range.location, length: range.length) }

    var range: NSRange { NSRange(location: start, length: length) }
}
