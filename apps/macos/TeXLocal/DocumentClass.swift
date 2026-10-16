import Foundation

/// The class a main file's `\documentclass` names, and the type size its options set.
nonisolated struct DocumentClass: Equatable, Decodable {
    var name: String
    var pointSize = 10
}

extension DocumentClass {
    /// The class named outside comments, read in the preamble first: the core's `document_class`.
    init?(in text: String) {
        guard let named: DocumentClass = Syntax.call("document_class", ["text": text]) else { return nil }
        self = named
    }
}

/// A level the class has, as its class file sets and numbers its headings (the core's `heading_styles`): Normal Text
/// first. A class it doesn't know has every level, numbered as a book's once the document has chapters.
nonisolated struct HeadingStyle: Equatable, Decodable {
    nonisolated struct Font: Equatable, Decodable {
        /// The size as a multiple of the text's.
        var scale: Double
        var bold: Bool
        var shape: Shape
    }

    nonisolated enum Shape: String, Decodable {
        case upright, italic, smallCaps
    }

    let title: String
    let command: String
    let font: Font
    /// Its number as its heading prints it, with the class's counters: "1.1" for a subsection.
    let marker: String?

    var level: HeadingLevel { HeadingLevel(title: title, command: command) }

    static func styles(of documentClass: DocumentClass?, hasChapters: Bool) -> [HeadingStyle] {
        var args: [String: Any] = ["hasChapters": hasChapters]
        if let documentClass {
            args["class"] = documentClass.name
            args["pointSize"] = documentClass.pointSize
        }
        return Syntax.call("heading_styles", args) ?? [HeadingStyle(title: HeadingLevel.normalText.title, command: "",
                                                                    font: Font(scale: 1, bold: false, shape: .upright), marker: nil)]
    }
}
