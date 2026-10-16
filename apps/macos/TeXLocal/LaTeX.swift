import Foundation

/// What the menus and the toolbar put in, the section levels and the maths symbols: the core's catalogue
/// (its syntax module's catalog.json), which every frontend's menus are made from.
nonisolated struct Menus: Decodable, Sendable {
    nonisolated struct Templates: Decodable, Sendable {
        let math: [Template]
        let insert: [Template]
        let list: [Template]
        /// Cross-references, citations and links.
        let references: [Template]
    }

    nonisolated struct Symbol: Decodable, Sendable {
        let glyph: String
        let command: String
    }

    nonisolated struct SymbolGroup: Decodable, Sendable {
        let title: String
        let symbols: [Symbol]
    }

    let templates: Templates
    /// Outermost first: indexed by the outline's depth.
    let headingLevels: [HeadingLevel]
    let symbolGroups: [SymbolGroup]

    static let shared: Menus = Syntax.call("menus", [:])
        ?? Menus(templates: Templates(math: [], insert: [], list: [], references: []), headingLevels: [], symbolGroups: [])
}

/// A block of the core's by its id, or with `inline` a command whose "$0" is where the selection goes.
/// `symbol` names the SF Symbol the toolbar shows it by, which makes it a toolbar button.
nonisolated struct Template: Decodable, Sendable {
    let title: String
    let body: String
    var symbol: String?
    let inline: Bool
}

extension ProjectModel {
    func insert(_ template: Template) {
        editor.perform(template.inline ? .inline(template: template.body, title: template.title)
                                       : .block(id: template.body, title: template.title))
    }
}

nonisolated struct HeadingLevel: Hashable, Decodable, Sendable {
    let title: String
    /// Without its backslash; empty for Normal Text.
    let command: String

    static let normalText = HeadingLevel(title: "Normal Text", command: "")

    static func atDepth(_ depth: Int) -> HeadingLevel? {
        let sections = Menus.shared.headingLevels
        return sections.indices.contains(depth) ? sections[depth] : nil
    }
}

enum TeXEngine: String, CaseIterable, Identifiable {
    case pdflatex, xelatex, lualatex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdflatex: "pdfLaTeX"
        case .xelatex: "XeLaTeX"
        case .lualatex: "LuaLaTeX"
        }
    }
}
