import AppKit
import SwiftUI

/// A file's kind at a glance, as Xcode's navigator shows it: a filled symbol in a colour of its own, raised to 3:1 against
/// the background in each appearance. Over a prominent selection it takes the selection's text colour instead.
struct FileIcon: View {
    /// Nil for a folder.
    let kind: FileKind?
    @Environment(\.backgroundProminence) private var prominence

    init(_ kind: FileKind?) { self.kind = kind }

    var body: some View {
        let look = Self.looks[kind]!
        Image(systemName: look.symbol)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(look.color))
    }

    private static func look(_ kind: FileKind?) -> (symbol: String, color: NSColor) {
        switch kind {
        case nil: ("folder.fill", .systemBlue)
        case .tex: ("text.document.fill", .systemGreen)
        case .bib: ("books.vertical.fill", .systemOrange)
        case .package: ("shippingbox.fill", .systemPurple)
        case .image: ("photo.fill", .systemTeal)
        case .pdf: ("richtext.page.fill", .systemRed)
        case .text: ("doc.plaintext.fill", .systemGray)
        case .other: ("document.fill", .systemGray)
        }
    }

    private static let looks = Dictionary(uniqueKeysWithValues: ([nil] + FileKind.allCases).map { kind in
        let look = look(kind)
        return (kind, (symbol: look.symbol, color: Color(nsColor: look.color.legible(ratio: 3))))
    })
}
