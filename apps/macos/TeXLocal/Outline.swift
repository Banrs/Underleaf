import Foundation

/// A heading and the headings under it.
nonisolated struct OutlineNode: Identifiable, Hashable {
    let item: OutlineItem
    let children: [OutlineNode]?

    var id: Int { item.id }
}

nonisolated struct OutlineItem: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
    /// An empty title; `Outline.displayTitle` names it by its kind.
    var isUntitled = false

    /// Its kind ("Subsection").
    var kind: String { HeadingLevel.atDepth(level)?.title ?? "Section" }
}

/// A document's analysis from the core's `analyze`: its headings, words and lines.
nonisolated struct Analysis: Decodable {
    struct Heading: Decodable {
        /// 0 for \part to 5 for \paragraph.
        let depth: Int
        let title: String
        let line: Int
    }

    let outline: [Heading]
    let words: Int
    let lines: Int

    static let untitledTitle = "(untitled)" // the core's placeholder (analyze.rs)

    var items: [OutlineItem] {
        outline.enumerated().map { index, heading in
            OutlineItem(id: index, level: heading.depth, title: heading.title, line: heading.line,
                        isUntitled: heading.title == Self.untitledTitle)
        }
    }
}

/// The outline as the views read it: nesting, folds, titles and the breadcrumb.
enum Outline {
    /// A document's outline, words and lines, from the core.
    static func analyze(_ text: String) async throws -> Analysis {
        try await Core.shared.call("analyze", ["text": text], as: Analysis.self)
    }

    /// Each heading's fold key ("1:Results#2"): level, title and occurrence, so a
    /// fold stays with its heading as others come and go above it.
    static func foldKeys(_ outline: [OutlineItem]) -> [String] {
        var seen: [String: Int] = [:]
        return outline.map { item in
            let key = "\(item.level):\(item.title)"
            seen[key, default: 0] += 1
            return "\(key)#\(seen[key]!)"
        }
    }

    /// The outline as a tree by how the headings nest: a subsection before
    /// any section sits flush rather than under a missing parent.
    static func tree(_ outline: [OutlineItem]) -> [OutlineNode] {
        var index = 0
        func nested(under level: Int) -> [OutlineNode] {
            var nodes: [OutlineNode] = []
            while index < outline.count, outline[index].level > level {
                let item = outline[index]
                index += 1
                let kids = nested(under: item.level)
                nodes.append(OutlineNode(item: item, children: kids.isEmpty ? nil : kids))
            }
            return nodes
        }
        return nested(under: -1)
    }

    /// An empty heading by its kind: "Untitled Subsection".
    static func displayTitle(_ item: OutlineItem) -> String {
        item.isUntitled ? "Untitled \(item.kind)" : item.title
    }

    /// The headings that enclose a line, outermost first: the breadcrumb.
    static func chain(_ outline: [OutlineItem], at line: Int) -> [OutlineItem] {
        var stack: [OutlineItem] = []
        for item in outline {
            if item.line > line { break }
            while let last = stack.last, last.level >= item.level { stack.removeLast() }
            stack.append(item)
        }
        return stack
    }
}
