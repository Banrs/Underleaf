/// A heading with what nests under it, as `session_analyze`'s `tree` has it; `foldKey` names its fold in the project's
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

/// A heading, by its place in the outline read in order: its sectioning command without the backslash, its level's name
/// ("Section"), and its title, its level's for one that has none (`untitled`): "Untitled Section".
nonisolated struct OutlineItem: Identifiable, Hashable, Decodable, Sendable {
    var id = 0
    let command: String
    let level: String
    let title: String
    let untitled: Bool
    let line: Int
    let file: String

    private enum CodingKeys: String, CodingKey {
        case command, level, title, untitled, line, file
    }
}

nonisolated struct Analysis: Decodable, Sendable {
    let tree: [OutlineNode]
    let words: Int
    /// The levels the main file's class has.
    let headingStyles: [HeadingStyle]

    /// The tree's headings in order, each at its `id`.
    var outline: [OutlineItem] { tree.flatMap { [$0] + $0.descendants }.map(\.item) }
}
