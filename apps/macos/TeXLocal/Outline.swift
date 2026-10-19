/// A heading with what nests under it, as `session_analyze`'s `tree` has it; `foldKey` names its fold in the project's
/// saved state. Equatable, so an analysis that finds the same headings changes nothing the outline shows.
nonisolated struct OutlineNode: Identifiable, Equatable, Decodable, Sendable {
    let item: OutlineItem
    let children: [OutlineNode]?
    let foldKey: String

    var id: Int { item.id }
    var descendants: [OutlineNode] { (children ?? []).flatMap { [$0] + $0.descendants } }

    private enum CodingKeys: String, CodingKey { case foldKey, children }

    /// The heading's fields sit beside its fold key and children.
    init(from decoder: any Decoder) throws {
        item = try OutlineItem(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        foldKey = try container.decode(String.self, forKey: .foldKey)
        children = try container.decodeIfPresent([OutlineNode].self, forKey: .children)
    }
}

/// A heading, by its place in the outline read in order (`index`): its sectioning command without the backslash, its
/// level's name ("Section"), and its title, its level's for one that has none (`untitled`): "Untitled Section".
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
    /// The levels the main file's class has.
    let headingStyles: [HeadingStyle]

    /// The tree's headings in order, each at its `id`.
    var outline: [OutlineItem] { tree.flatMap { [$0] + $0.descendants }.map(\.item) }
}
