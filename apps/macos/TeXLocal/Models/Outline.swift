nonisolated extension OutlineNode: Identifiable {
    var id: Int { index }
    var descendants: [OutlineNode] { (children ?? []).flatMap { [$0] + $0.descendants } }
}

nonisolated extension Analysis {
    var outline: [Heading] { tree.flatMap { [$0] + $0.descendants }.map(\.heading) }
}
