/// A heading with what nests under it (`session_analyze`'s `tree`); `foldKey` names its fold in the project's saved state.
nonisolated struct OutlineNode: Identifiable, Equatable, Decodable, Sendable {
    let item: OutlineItem
    let children: [OutlineNode]?
    let foldKey: String

    var id: Int { item.id }
    var descendants: [OutlineNode] { (children ?? []).flatMap { [$0] + $0.descendants } }

    private enum CodingKeys: String, CodingKey { case foldKey, children }

    init(from decoder: any Decoder) throws {
        item = try OutlineItem(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        foldKey = try container.decode(String.self, forKey: .foldKey)
        children = try container.decodeIfPresent([OutlineNode].self, forKey: .children)
    }
}

/// A heading by its place in the outline: its command without the backslash, its level's name, and its title
/// ("Untitled Section" for one with none).
nonisolated struct OutlineItem: Identifiable, Hashable, Decodable, Sendable {
    let id: Int
    let command, level, title: String
    let untitled: Bool
    let line: Int
    let file: String

    private enum CodingKeys: String, CodingKey { case id = "index", command, level, title, untitled, line, file }
}

nonisolated struct Analysis: Decodable, Sendable {
    let tree: [OutlineNode]
    let words: Int
    let headingStyles: [HeadingStyle]

    var outline: [OutlineItem] { tree.flatMap { [$0] + $0.descendants }.map(\.item) }
}
