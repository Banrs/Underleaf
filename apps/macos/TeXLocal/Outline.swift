import Foundation

/// A heading and the headings under it.
struct OutlineNode: Identifiable, Hashable {
    let item: OutlineItem
    let children: [OutlineNode]?

    var id: Int { item.id }
}

struct OutlineItem: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
    /// A heading with an empty title, which `title` spells "(untitled)" as
    /// the web does; `Outline.displayTitle` names it by its kind.
    var isUntitled = false

    /// Its kind ("Subsection"), one of the source bar's section levels.
    var kind: String { headingLevels.indices.contains(level + 1) ? headingLevels[level + 1].0 : "Section" }
}

/// A document's analysis, from the core's `analyze` (web/src/state.js
/// `analyzeDoc`, checked against the same fixtures): its headings, and
/// its words and lines, lines broken where the editor breaks them.
struct Analysis: Decodable {
    struct Heading: Decodable {
        /// 0 for \part to 5 for \paragraph.
        let depth: Int
        let title: String
        let line: Int
    }

    let outline: [Heading]
    let words: Int
    let lines: Int

    /// The headings as the views take them. An empty title comes back as
    /// the web's "(untitled)".
    var items: [OutlineItem] {
        outline.enumerated().map { index, heading in
            OutlineItem(id: index, level: heading.depth, title: heading.title, line: heading.line,
                        isUntitled: heading.title == "(untitled)")
        }
    }
}

/// The outline as the views read it: nesting, folds, titles and the
/// breadcrumb.
enum Outline {
    /// A document's outline, words and lines, from the core.
    @MainActor
    static func analyze(_ text: String) async throws -> Analysis {
        try await Core.shared.call("analyze", ["text": text], as: Analysis.self)
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

    /// Each heading's key for remembering its fold: its level and title,
    /// and which of the headings with both it is ("1:Results#2"), so a fold
    /// stays with its heading as others come and go above it.
    static func foldKeys(_ outline: [OutlineItem]) -> [String] {
        var seen: [String: Int] = [:]
        return outline.map { item in
            let key = "\(item.level):\(item.title)"
            seen[key, default: 0] += 1
            return "\(key)#\(seen[key]!)"
        }
    }

    /// The outline as a tree by how the headings nest, for the sidebar's
    /// disclosure triangles.
    static func tree(_ outline: [OutlineItem]) -> [OutlineNode] {
        let depths = depths(outline)
        var index = 0
        func children(at depth: Int) -> [OutlineNode] {
            var nodes: [OutlineNode] = []
            while index < outline.count, depths[index] == depth {
                let item = outline[index]
                index += 1
                let kids = children(at: depth + 1)
                nodes.append(OutlineNode(item: item, children: kids.isEmpty ? nil : kids))
            }
            return nodes
        }
        return children(at: 0)
    }

    /// An empty heading by its kind — "Untitled Subsection" — where the web
    /// writes "(untitled)".
    static func displayTitle(_ item: OutlineItem) -> String {
        item.isUntitled ? "Untitled \(item.kind)" : item.title
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
}
