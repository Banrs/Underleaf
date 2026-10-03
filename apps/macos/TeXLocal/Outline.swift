import Foundation

nonisolated struct OutlineNode: Identifiable {
    let item: OutlineItem
    let children: [OutlineNode]?

    var id: Int { item.id }
}

nonisolated struct OutlineItem: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
    let file: String

    /// An empty title; `Outline.displayTitle` names it by its kind.
    var isUntitled: Bool { title == Analysis.untitledTitle }

    var kind: String { HeadingLevel.atDepth(level)?.title ?? "Section" }
}

/// `analyze_project`'s headings, word count and open-file line count.
nonisolated struct Analysis: Decodable {
    struct Heading: Decodable {
        /// 0 for \part to 5 for \paragraph.
        let depth: Int
        let title: String
        let line: Int
        let file: String
    }

    let outline: [Heading]
    let words: Int
    let lines: Int

    static let untitledTitle = "(untitled)" // the core's placeholder (analyze.rs)

    var items: [OutlineItem] {
        outline.enumerated().map { index, heading in
            OutlineItem(id: index, level: heading.depth, title: heading.title, line: heading.line, file: heading.file)
        }
    }
}

/// The outline as the views read it: nesting, folds, titles and the breadcrumb.
enum Outline {
    static func analyze(project: String, file: String) async throws -> Analysis {
        try await Core.shared.call("analyze_project", ["id": project, "file": file], as: Analysis.self)
    }

    /// Each heading's fold key ("main.tex\t1:Results#2"): file, level, title and occurrence
    /// in the file, so a fold stays with its heading as others come and go above it.
    static func foldKeys(_ outline: [OutlineItem]) -> [String] {
        var seen: [String: Int] = [:]
        return outline.map { item in
            let key = "\(item.file)\t\(item.level):\(item.title)"
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

    static func displayTitle(_ item: OutlineItem) -> String {
        item.isUntitled ? "Untitled \(item.kind)" : item.title
    }

    /// The heading a line of a file is under: the file's last at or above it. Above its
    /// first there's none, since where the file is read in isn't known.
    static func current(_ outline: [OutlineItem], file: String?, line: Int) -> Int? {
        outline.lastIndex { $0.file == file && $0.line <= line }
    }

    /// The heading at `index` and those enclosing it, outermost first.
    static func chain(_ outline: [OutlineItem], to index: Int?) -> [OutlineItem] {
        var stack: [OutlineItem] = []
        for item in outline.prefix(index.map { $0 + 1 } ?? 0) {
            while let last = stack.last, last.level >= item.level { stack.removeLast() }
            stack.append(item)
        }
        return stack
    }
}
