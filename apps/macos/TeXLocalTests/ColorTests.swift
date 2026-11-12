import AppKit
import Testing
@testable import TeXLocal

struct ColorTests {
    private func ratio(_ color: NSColor, in name: NSAppearance.Name) -> Double {
        let appearance = NSAppearance(named: name)!
        return NSColor.contrast(color.rgba(in: appearance), NSColor.textBackgroundColor.rgba(in: appearance))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua], HighlightKind.allCases)
    func syntaxColoursAreLegible(_ name: NSAppearance.Name, _ kind: HighlightKind) {
        let shown = ratio(kind.color, in: name)
        #expect(shown >= 4.45, "\(kind) in \(name.rawValue): \(shown)")
    }

    @Test(arguments: [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua],
          [NSColor.systemYellow, .systemBlue, .systemGray, .secondaryLabelColor])
    func highContrastRaisesTextToSevenToOne(_ name: NSAppearance.Name, _ color: NSColor) {
        let shown = ratio(color.legibleAsText(in: name), in: name)
        #expect(shown >= 6.95, "\(color) in \(name.rawValue): \(shown)")
    }

    @Test func aColourAlreadyLegibleKeepsItsValue() {
        let black = NSColor.black.legibleAsText(in: .aqua)
        #expect(black.rgba(in: NSAppearance(named: .aqua)!) == [0, 0, 0, 1])
    }

    @Test func contrastRunsFromOneToTwentyOne() {
        #expect(NSColor.contrast([0, 0, 0, 1], [1, 1, 1, 1]) == 21)
        #expect(NSColor.contrast([0.5, 0.5, 0.5, 1], [0.5, 0.5, 0.5, 1]) == 1)
    }

    @Test(arguments: await NSColor.textAppearances, [NSColor.systemPink, .systemTeal, .systemYellow, .secondaryLabelColor])
    func raisedTextStaysLegibleOverTheCurrentLine(_ name: NSAppearance.Name, _ color: NSColor) throws {
        let appearance = try #require(NSAppearance(named: name))
        let line = NSColor.currentLine.rgba(in: appearance)
        #expect(line[0] == line[1] && line[1] == line[2])
        let background = NSColor.textBackgroundColor.rgba(in: appearance)
        let shown = zip(background, line).map { $0 * (1 - line[3]) + $1 * line[3] }
        #expect(NSColor.contrast(shown, background) > 1.1)
        let ratio = NSColor.contrast(color.legibleAsText(in: name).rgba(in: appearance), shown)
        #expect(ratio >= (name == .aqua || name == .darkAqua ? 4.45 : 6.95), "\(color) in \(name.rawValue): \(ratio)")
    }

    @Test(arguments: await NSColor.textAppearances, [false, true])
    func issueUnderlinesStandOutFromTheText(_ name: NSAppearance.Name, _ error: Bool) throws {
        // As legible as text. NSAppearance(named:) gives the plain appearance for a high-contrast name, so each
        // resolves to its 4.5:1 colour here; the 7:1 one shows only with Increase Contrast on.
        let shown = ratio(try #require(IssueBox.underlines[error]), in: name)
        #expect(shown >= 4.45, "\(error) in \(name.rawValue): \(shown)")
    }
}
