nonisolated struct OutlineNode: Identifiable, Equatable, Decodable, Sendable {
    let item: OutlineItem
    let children: [OutlineNode]?
    let foldKey: String
    let words: Int

    var id: Int { item.id }
    var descendants: [OutlineNode] { (children ?? []).flatMap { [$0] + $0.descendants } }

    private enum CodingKeys: String, CodingKey { case foldKey, children, words }

    init(from decoder: any Decoder) throws {
        item = try OutlineItem(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        foldKey = try container.decode(String.self, forKey: .foldKey)
        children = try container.decodeIfPresent([OutlineNode].self, forKey: .children)
        words = try container.decode(Int.self, forKey: .words)
    }
}

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
