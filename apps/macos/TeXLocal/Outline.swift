import Foundation

struct OutlineItem: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
}

/// Sectioning commands in a document, as the browser version's outline reads
/// them (web/src/state.js `SECTION_RE`).
enum Outline {
    private static let levels = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph"]

    static func parse(_ text: String) -> [OutlineItem] {
        // Local rather than a static: Regex is not Sendable.
        let pattern = /\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/
        var items: [OutlineItem] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            if line.drop(while: \.isWhitespace).hasPrefix("%") { return }
            guard let m = line.firstMatch(of: pattern) else { return }
            items.append(OutlineItem(
                id: items.count,
                level: levels.firstIndex(of: String(m.1)) ?? 2,
                title: m.2.isEmpty ? "(untitled)" : String(m.2),
                line: number
            ))
        }
        return items
    }
}
