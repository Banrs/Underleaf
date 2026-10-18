import Foundation

/// What the menus and the toolbar put in and the maths symbols: the core's catalogue (its syntax module's catalog.json),
/// which every frontend's menus are made from.
nonisolated struct Menus: Decodable, Sendable {
    nonisolated struct Templates: Decodable, Sendable {
        let math, insert, list: [Template]
        /// Cross-references, citations and links.
        let references: [Template]
    }

    nonisolated struct Symbol: Decodable, Sendable {
        let glyph, command: String
    }

    nonisolated struct SymbolGroup: Decodable, Sendable {
        let title: String
        let symbols: [Symbol]
    }

    let templates: Templates
    let symbolGroups: [SymbolGroup]

    static let shared: Menus = Syntax.call("menus", [:])
        ?? Menus(templates: Templates(math: [], insert: [], list: [], references: []), symbolGroups: [])
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

/// A level the main file's class has, as its class file sets and numbers its headings (`session_analyze`'s
/// `headingStyles`): Normal Text first.
nonisolated struct HeadingStyle: Equatable, Decodable, Sendable {
    nonisolated struct Font: Equatable, Decodable, Sendable {
        /// The size as a multiple of the text's.
        var scale: Double
        var bold: Bool
        var shape: Shape
    }

    nonisolated enum Shape: String, Decodable, Sendable { case upright, italic, smallCaps }

    let title: String
    /// Without its backslash; empty for Normal Text.
    let command: String
    let font: Font
    /// Its number as its heading prints it, with the class's counters: "1.1" for a subsection.
    let marker: String?

    /// Without a class: every level, set as the standard classes set them (`heading_styles`).
    static let standard: [HeadingStyle] = Syntax.call("heading_styles", [:])
        ?? [HeadingStyle(title: "Normal Text", command: "", font: Font(scale: 1, bold: false, shape: .upright), marker: nil)]
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
