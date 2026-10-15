nonisolated struct OutlineNode: Identifiable {
    let item: OutlineItem
    let children: [OutlineNode]?
    let foldKey: String

    var id: Int { item.id }
    var descendants: [OutlineNode] { (children ?? []).flatMap { [$0] + $0.descendants } }
}

nonisolated struct OutlineItem: Identifiable, Hashable, Decodable {
    var id = 0
    let level: Int
    let title: String
    let line: Int
    let file: String

    private enum CodingKeys: String, CodingKey {
        case level = "depth", title, line, file
    }

    var isUntitled: Bool { title == "(untitled)" }

    var displayTitle: String { isUntitled ? "Untitled \(kind)" : title }

    var kind: String { HeadingLevel.atDepth(level)?.title ?? "Section" }
}

nonisolated struct Analysis: Decodable {
    let outline: [OutlineItem]
    let words: Int
}

enum Outline {
    /// A subsection before any section sits flush rather than under a missing parent.
    static func tree(_ outline: [OutlineItem]) -> [OutlineNode] {
        var index = 0
        var seen: [String: Int] = [:]
        func nested(under level: Int) -> [OutlineNode] {
            var nodes: [OutlineNode] = []
            while index < outline.count, outline[index].level > level {
                let item = outline[index]
                index += 1
                let key = "\(item.file)\t\(item.level):\(item.title)"
                seen[key, default: 0] += 1
                let kids = nested(under: item.level)
                nodes.append(OutlineNode(item: item, children: kids.isEmpty ? nil : kids, foldKey: "\(key)#\(seen[key]!)"))
            }
            return nodes
        }
        return nested(under: -1)
    }

    /// Above its first there's none, since where the file is read in isn't known.
    static func current(_ outline: [OutlineItem], file: String?, line: Int) -> Int? {
        outline.lastIndex { $0.file == file && $0.line <= line }
    }
}
