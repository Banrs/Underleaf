import Foundation

nonisolated struct OutlineNode: Identifiable {
    let item: OutlineItem
    let children: [OutlineNode]?

    var id: Int { item.id }
}

/// A heading from `analyze_project`; its id is its place in the outline.
nonisolated struct OutlineItem: Identifiable, Hashable, Decodable {
    var id = 0
    /// 0 for \part to 5 for \paragraph.
    let level: Int
    let title: String
    let line: Int
    let file: String

    private enum CodingKeys: String, CodingKey {
        case level = "depth", title, line, file
    }

    /// An empty title, the core's placeholder (analyze.rs).
    var isUntitled: Bool { title == "(untitled)" }

    var displayTitle: String { isUntitled ? "Untitled \(kind)" : title }

    var kind: String { HeadingLevel.atDepth(level)?.title ?? "Section" }
}

/// `analyze_project`'s headings, word count and open-file line count.
nonisolated struct Analysis: Decodable {
    let outline: [OutlineItem]
    let words: Int
    let lines: Int
}

/// The outline's nesting and the heading a line is under.
enum Outline {
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

    /// The heading a line of a file is under: the file's last at or above it. Above its
    /// first there's none, since where the file is read in isn't known.
    static func current(_ outline: [OutlineItem], file: String?, line: Int) -> Int? {
        outline.lastIndex { $0.file == file && $0.line <= line }
    }
}
