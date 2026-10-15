/// A heading with what nests under it, as `analyze_project`'s `tree` has it; `foldKey` names its fold in the project's
/// saved state.
nonisolated struct OutlineNode: Identifiable, Decodable, Sendable {
    let item: OutlineItem
    let children: [OutlineNode]?
    let foldKey: String

    var id: Int { item.id }
    var descendants: [OutlineNode] { (children ?? []).flatMap { [$0] + $0.descendants } }

    private enum CodingKeys: String, CodingKey {
        case index, foldKey, children
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var item = try OutlineItem(from: decoder)
        item.id = try container.decode(Int.self, forKey: .index)
        self.item = item
        foldKey = try container.decode(String.self, forKey: .foldKey)
        children = try container.decodeIfPresent([OutlineNode].self, forKey: .children)
    }
}

nonisolated struct OutlineItem: Identifiable, Hashable, Decodable, Sendable {
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

    /// As `outline_current` takes it.
    var heading: [String: any Sendable] { ["depth": level, "title": title, "line": line, "file": file] }
}

nonisolated struct Analysis: Decodable, Sendable {
    let outline: [OutlineItem]
    let words: Int
    let tree: [OutlineNode]
}
