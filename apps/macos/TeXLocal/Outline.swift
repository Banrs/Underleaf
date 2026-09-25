import Foundation

struct OutlineItem: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
}

/// Sectioning commands in a document, as the browser version's outline reads
/// them (web/src/state.js `SECTION_RE`), and the word count read alongside.
enum Outline {
    private static let levels = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph"]

    static func parse(_ text: String) -> [OutlineItem] {
        analyze(text).outline
    }

    /// The outline, words and lines in one pass (web/src/state.js
    /// `analyzeDoc`). Lines break where CodeMirror breaks them — at CR LF, CR
    /// or LF — so the line count is the editor's.
    static func analyze(_ text: String) -> (outline: [OutlineItem], words: Int, lines: Int) {
        // Local rather than a static: Regex is not Sendable.
        let pattern = /\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/
        var items: [OutlineItem] = []
        var words = 0
        var lines = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            lines += 1
            if isComment(line) { continue }
            if let m = line.firstMatch(of: pattern) {
                items.append(OutlineItem(
                    id: items.count,
                    level: levels.firstIndex(of: String(m.1)) ?? 2,
                    title: m.2.isEmpty ? "(untitled)" : String(m.2),
                    line: lines
                ))
            }
            words += lineWords(line)
        }
        return (items, words, lines)
    }

    /// Each heading's depth in the document's actual nesting: how many
    /// headings enclose it. A subsection before any section sits flush,
    /// rather than indented under a parent that isn't there.
    static func depths(_ outline: [OutlineItem]) -> [Int] {
        var stack: [Int] = []
        return outline.map { item in
            while let last = stack.last, last >= item.level { stack.removeLast() }
            stack.append(item.level)
            return stack.count - 1
        }
    }

    /// An empty heading by its kind — "Untitled Subsection" — where the web
    /// writes "(untitled)".
    static func displayTitle(_ item: OutlineItem) -> String {
        guard item.title == "(untitled)" else { return item.title }
        let kinds = ["Part", "Chapter", "Section", "Subsection", "Subsubsection", "Paragraph"]
        return "Untitled " + (kinds.indices.contains(item.level) ? kinds[item.level] : "Section")
    }

    /// The headings that enclose a line, outermost first: the breadcrumb
    /// (web/src/state.js `outlineChain`).
    static func chain(_ outline: [OutlineItem], at line: Int) -> [OutlineItem] {
        var stack: [OutlineItem] = []
        for item in outline {
            if item.line > line { break }
            while let last = stack.last, last.level >= item.level { stack.removeLast() }
            stack.append(item)
        }
        return stack
    }

    // ---------- word count ----------

    // The rules below are web/src/state.js `lineWords`, whose regular
    // expressions run on JavaScript's terms; they are spelled out over Unicode
    // scalars here so that every line counts the same in both.

    /// JavaScript's `\s`.
    private static let whitespace = Set("\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}".unicodeScalars)
    /// TeX's special characters, which separate words like spaces do.
    private static let special = Set("{}$&_^~\\%".unicodeScalars)

    /// A line whose first non-space character is `%`.
    private static func isComment(_ line: Substring) -> Bool {
        line.unicodeScalars.first(where: { !whitespace.contains($0) }) == "%"
    }

    /// Rough word count of a prose line: drop the comment, then commands with
    /// a star and one [argument], then TeX's special characters, and count the
    /// runs left that contain a letter.
    static func lineWords(_ line: Substring) -> Int {
        var text = Array(line.unicodeScalars)
        if let comment = commentStart(text) { text.removeSubrange(comment...) }
        var words = 0
        var letter = false
        var i = 0
        // One step past the end, as a space, closes the last run.
        while i <= text.count {
            let c: Unicode.Scalar = i < text.count ? text[i] : " "
            if c == "\\", i + 1 < text.count, isASCIILetter(text[i + 1]) {
                i += 1
                while i < text.count, isASCIILetter(text[i]) { i += 1 }
                if i < text.count, text[i] == "*" { i += 1 }
                if i < text.count, text[i] == "[", let close = text[(i + 1)...].firstIndex(of: "]") { i = close + 1 }
                if letter { words += 1 }
                letter = false
                continue
            }
            if whitespace.contains(c) || special.contains(c) {
                if letter { words += 1 }
                letter = false
            } else if isWordLetter(c) {
                letter = true
            }
            i += 1
        }
        return words
    }

    /// The first `%` no backslash escapes. JavaScript's `.` stops at U+2028
    /// and U+2029, so a `%` with either after it starts no comment there.
    private static func commentStart(_ text: [Unicode.Scalar]) -> Int? {
        let from = text.lastIndex(where: { $0 == "\u{2028}" || $0 == "\u{2029}" }).map { $0 + 1 } ?? 0
        return (from..<text.count).first(where: { i in
            text[i] == "%" && (i == 0 || text[i - 1] != "\\")
        })
    }

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(c.value) || (0x61...0x7A).contains(c.value)
    }

    /// `[A-Za-zÀ-ž]`.
    private static func isWordLetter(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || (0xC0...0x17E).contains(c.value)
    }
}
