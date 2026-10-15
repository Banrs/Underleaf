import Foundation

/// The class a main file's `\documentclass` names, and the type size its options set.
nonisolated struct DocumentClass: Equatable {
    var name: String
    /// 10, 11 or 12 (points): LaTeX's size options, which set what `\large` and the rest are.
    var pointSize = 10
}

extension DocumentClass {
    /// The class named outside comments, if any.
    init?(in text: String) {
        let named = { (text: Substring) in
            // A comment runs from a % that isn't escaped to the line's end, however the line ends:
            // `.` stops at a line break, where `[^\n]` took a CRLF, one Character, for the comment's.
            text.replacing(/(^|[^\\])%.*/.anchorsMatchLineEndings()) { $0.1 }
                .firstMatch(of: /\\documentclass\s*(?:\[([^\]]*)\])?\s*\{\s*([^}\s]+)\s*\}/)
        }
        // LaTeX takes the class in the preamble, so the text up to the first \begin{document}
        // after a class is named is read first, and the whole only when that has none (a
        // \begin{document} in a comment, say). Each save of the main file reads it on the main
        // actor: a 470 KB file's comments took 37 ms to take out, its preamble's 0.3 ms.
        let preamble = text.firstRange(of: "\\documentclass")
            .flatMap { text[$0.upperBound...].firstRange(of: "\\begin{document}") }
            .map { text[..<$0.upperBound] }
        guard let match = preamble.flatMap(named) ?? named(text[...]) else { return nil }
        name = String(match.2)
        let options = match.1.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } } ?? []
        // KOMA-Script's fontsize=11pt as well as the standard 11pt.
        pointSize = [11, 12].first { size in options.contains { $0 == "\(size)pt" || $0 == "fontsize=\(size)pt" } } ?? 10
    }
}

/// How a document's class sets its headings, as its class file does (TeX Live's base, amscls,
/// koma-script, memoir, IEEEtran and llncs): the levels it has, and each one's size against the
/// text's, its weight and its shape. A class it doesn't know has every level, set as the
/// standard classes set them.
nonisolated struct HeadingStyles: Equatable {
    /// A level's look: its size as a multiple of the text's, bold or not, and its shape.
    struct Font: Equatable {
        var scale: Double
        var bold: Bool
        var shape: Shape
    }

    enum Shape { case upright, italic, smallCaps }

    /// Normal Text, then the levels the class has.
    let levels: [HeadingLevel]
    private let fonts: [String: Font]

    private enum Family { case article, book, amsArticle, amsBook, komaArticle, komaBook, ieee, llncs, unsectioned }

    private static let families: [String: Family] = [
        "article": .article, "proc": .article, "report": .book, "book": .book, "memoir": .book,
        "amsart": .amsArticle, "amsproc": .amsArticle, "amsbook": .amsBook,
        "scrartcl": .komaArticle, "scrreprt": .komaBook, "scrbook": .komaBook,
        "IEEEtran": .ieee, "llncs": .llncs, "letter": .unsectioned, "minimal": .unsectioned,
    ]

    /// The size commands, from \normalsize up.
    private enum Size: Int { case normalsize, large, Large, LARGE, huge, Huge }

    /// size10.clo, size11.clo and size12.clo, in points.
    private static let points: [Int: [Double]] = [
        10: [10, 12, 14.4, 17.28, 20.74, 24.88],
        11: [10.95, 12, 14.4, 17.28, 20.74, 24.88],
        12: [12, 14.4, 17.28, 20.74, 24.88, 24.88],
    ]

    init(documentClass: DocumentClass?) {
        let family = documentClass.flatMap { Self.families[$0.name] }
        let sizes = Self.points[documentClass?.pointSize ?? 10] ?? Self.points[10]!
        let bold = { (size: Size) in Font(scale: sizes[size.rawValue] / sizes[0], bold: true, shape: .upright) }
        let plain = { (shape: Shape) in Font(scale: 1, bold: false, shape: shape) }
        // The standard classes' (article.cls, book.cls): every level bold, and so memoir's.
        var fonts: [String: Font] = [
            "part": bold(.Huge), "chapter": bold(.Huge), "section": bold(.Large),
            "subsection": bold(.large), "subsubsection": bold(.normalsize), "paragraph": bold(.normalsize),
        ]
        var commands = HeadingLevel.sections.map(\.command)
        switch family {
        case .article?:
            fonts["part"] = bold(.huge)
            commands.removeAll { $0 == "chapter" }
        case .amsArticle?:
            fonts = ["part": bold(.normalsize), "section": plain(.smallCaps), "subsection": bold(.normalsize),
                     "subsubsection": plain(.italic), "paragraph": plain(.upright)]
            commands.removeAll { $0 == "chapter" }
        case .amsBook?:
            // \@xxpt and \@xivpt, whatever the size option.
            fonts = ["part": Font(scale: 20.74 / sizes[0], bold: true, shape: .upright),
                     "chapter": Font(scale: 14.4 / sizes[0], bold: true, shape: .upright),
                     "section": bold(.normalsize), "subsection": bold(.normalsize),
                     "subsubsection": plain(.italic), "paragraph": plain(.upright)]
        case .komaArticle?:
            commands.removeAll { $0 == "chapter" }
        case .komaBook?:
            // headings=big, KOMA-Script's default.
            fonts["chapter"] = bold(.huge)
        case .ieee?:
            fonts = ["section": plain(.smallCaps), "subsection": plain(.italic),
                     "subsubsection": plain(.italic), "paragraph": plain(.italic)]
            commands.removeAll { $0 == "part" || $0 == "chapter" }
        case .llncs?:
            fonts["section"] = bold(.large)
            fonts["subsection"] = bold(.normalsize)
            fonts["paragraph"] = plain(.italic)
            commands.removeAll { $0 == "chapter" }
        case .unsectioned?:
            commands = []
        case .book?, nil:
            break
        }
        self.fonts = fonts
        levels = [.normalText] + HeadingLevel.sections.filter { commands.contains($0.command) }
    }

    func font(_ level: HeadingLevel) -> Font {
        fonts[level.command] ?? Font(scale: 1, bold: false, shape: .upright)
    }
}
