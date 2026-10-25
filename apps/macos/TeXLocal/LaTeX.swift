import Foundation

/// The core's catalogue of what the menus and toolbar put in, which every host's menus are made from.
nonisolated struct Menus: Decodable, Sendable {
    nonisolated struct Templates: Decodable, Sendable {
        let math, insert, list, references: [Template]
    }

    nonisolated struct Symbol: Decodable, Sendable { let glyph, command: String }

    nonisolated struct SymbolGroup: Decodable, Sendable {
        let title: String
        let symbols: [Symbol]
    }

    let templates: Templates
    let symbolGroups: [SymbolGroup]

    static let shared: Menus = Syntax.call("menus", [:])!
}

/// A block of the core's by its id, or with `inline` a command whose "$0" is where the selection goes; one with a
/// `symbol` is a toolbar button.
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

nonisolated struct HeadingStyle: Decodable, Sendable {
    let title, command: String
    static let standard: [HeadingStyle] = Syntax.call("heading_styles", [:])!
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
