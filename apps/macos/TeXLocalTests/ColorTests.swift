import AppKit
import Testing
@testable import TeXLocal

struct ColorTests {
    private func ratio(_ color: NSColor, in name: NSAppearance.Name) -> Double {
        let appearance = NSAppearance(named: name)!
        return NSColor.contrast(color.rgba(in: appearance), NSColor.textBackgroundColor.rgba(in: appearance))
    }

    @Test func syntaxColoursAreLegible() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for theme in SyntaxTheme.allCases {
                for kind in HighlightKind.allCases {
                    let shown = ratio(theme.color(kind), in: name)
                    #expect(shown >= 4.45, "\(theme) \(kind) in \(name.rawValue): \(shown)")
                    #expect(theme.color(kind) != .textColor, "\(theme) \(kind)")
                }
            }
        }
    }

    @Test func highContrastRaisesTextToSevenToOne() {
        for name in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            for color in [NSColor.systemYellow, .systemBlue, .systemGray, .secondaryLabelColor] {
                let shown = ratio(color.legibleAsText(in: name), in: name)
                #expect(shown >= 6.95, "\(color) in \(name.rawValue): \(shown)")
            }
        }
    }

    @Test func aColourAlreadyLegibleKeepsItsValue() {
        let black = NSColor.black.legibleAsText(in: .aqua)
        #expect(black.rgba(in: NSAppearance(named: .aqua)!) == [0, 0, 0, 1])
    }

    @Test func contrastRunsFromOneToTwentyOne() {
        #expect(NSColor.contrast([0, 0, 0, 1], [1, 1, 1, 1]) == 21)
        #expect(NSColor.contrast([0.5, 0.5, 0.5, 1], [0.5, 0.5, 0.5, 1]) == 1)
    }
}
