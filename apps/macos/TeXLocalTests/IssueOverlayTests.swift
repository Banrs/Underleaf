import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

@MainActor
struct IssueOverlayTests {
    @Test(arguments: [false, true])
    func aWrappedIssueKeepsItsIconOnTheFirstRowAndItsClickTarget(live: Bool) throws {
        let prefix = String(repeating: "x", count: 80)
        let command = "\\undefinedcommand"
        let source = prefix + command + "$.\nAfter"
        let (editor, window) = EditorTests.editor(source)
        defer { window.close() }
        let text = editor.textView
        text.fontSize = 13
        window.setContentSize(NSSize(width: 260, height: 400))
        window.displayIfNeeded()
        let original = try #require(text.fragments.first?.fragment.textLineFragments.first?.characterRange)
        let scale = window.backingScaleFactor
        let font = try #require(text.font)
        let expectedThicknessPixels = (2 * font.underlineThickness * scale).rounded()
        let expectedDropPixels = (-font.underlinePosition * scale).rounded(.down)
        if scale == 2 { #expect(expectedThicknessPixels == 3 && expectedDropPixels == 2) }
        let message = Message(id: .tex, args: [:], text: "Undefined control sequence.")
        let issue = IssueLine(line: 1, error: true, message: message, short: message, compact: nil,
                              tokens: [TextRange(start: prefix.utf16.count, length: command.utf16.count)], others: [], index: 0)
        if live { text.issues.live = [1: issue] } else { text.issues.lines = [1: issue] }

        for width in [260, 1200, 260] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 400))
            window.displayIfNeeded()
            let fragment = try #require(text.fragments.first?.fragment)
            let first = try #require(fragment.textLineFragments.first)
            let row = try #require(text.issues.rows.first { $0.line == 1 })
            let badge = try #require(row.message)
            #expect(badge.view.superview === text && badge.rect.width > 0 && badge.rect.height > 0)
            #expect(abs(badge.rect.maxX - row.band.maxX) < 0.5 && abs(badge.rect.minY - row.band.minY) < 0.5)
            #expect(badge.rect.maxY == text.onPixels(text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                                                     + first.typographicBounds.maxY + text.halfLineSpacing))
            if width == 1200 { #expect(badge.rect.minY == row.band.minY && badge.rect.maxY == row.band.maxY) }
            let textEnd = text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + first.typographicBounds.maxX
            #expect(textEnd < badge.rect.minX)
            // Xcode's 3 px underline, 2 px below the baseline, at 2×.
            let baselines = Set(fragment.textLineFragments.map {
                text.onPixels(text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + $0.typographicBounds.minY + $0.glyphOrigin.y)
            })
            #expect(!row.tokens.isEmpty && row.tokens.allSatisfy {
                $0.height * scale == expectedThicknessPixels && baselines.contains($0.minY - expectedDropPixels / scale)
            })
            #expect(text.issues.message(at: NSPoint(x: badge.rect.midX, y: badge.rect.midY))?.line == 1)
            if width == 260 {
                #expect(fragment.textLineFragments.count > 1 && NSMaxRange(first.characterRange) <= prefix.utf16.count)
                #expect(badge.view.rootView.text == nil && badge.cut && row.tip == message.text)
            } else {
                #expect(fragment.textLineFragments.count == 1)
                #expect(badge.view.rootView.text == message.text && !badge.cut)
            }
        }

        text.selection = .caret(text.length)
        window.makeFirstResponder(nil)
        window.displayIfNeeded()
        #expect(text.issues.rows.first { $0.line == 1 }?.message != nil)
        text.issues.lines = [:]
        text.issues.live = [:]
        window.displayIfNeeded()
        #expect(text.issues.rows.isEmpty)
        #expect(text.fragments.first?.fragment.textLineFragments.first?.characterRange == original)
        #expect(text.string == source && !text.undo.canUndo)
    }
}
