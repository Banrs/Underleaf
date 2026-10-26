import AppKit
import Testing
@testable import TeXLocal

struct LogTextViewTests {
    @Test func liveOutputKeepsTheSelectedErrorAndReadingPosition() throws {
        let (scroll, view) = try logScroll()
        let initial = view.string
        let selection = NSRange(location: 12, length: 8)
        view.setSelectedRange(selection)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)

        LogTextView(text: initial + "new output\n").updateText(in: scroll)
        #expect(view.selectedRange() == selection && scroll.contentView.bounds.origin == origin && view.string == initial + "new output\n")

        LogTextView(text: "é\n").updateText(in: scroll)
        #expect(view.selectedRange() == .caret(2))
        LogTextView(text: "e\u{301}\nnext\n").updateText(in: scroll)
        #expect(view.string.utf16.elementsEqual("e\u{301}\nnext\n".utf16))
    }

    @Test func findStopsFollowingTheLiveTail() throws {
        let (scroll, view) = try logScroll()
        scroll.findBarView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        scroll.isFindBarVisible = true
        view.scrollToEndOfDocument(nil)
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)
        LogTextView(text: view.string + String(repeating: "more output\n", count: 50)).updateText(in: scroll)
        #expect(scroll.contentView.bounds.origin == origin)
    }

    @Test func aBarInsetKeepsAnAtEndLogFollowing() throws {
        let (scroll, view) = try logScroll()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets.bottom = 28
        view.scrollToEndOfDocument(nil)
        let end = scroll.contentView.bounds.origin.y
        LogTextView(text: view.string + String(repeating: "more output\n", count: 50)).updateText(in: scroll)
        #expect(scroll.contentView.bounds.origin.y > end)
    }

    private func logScroll() throws -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.setFrameSize(NSSize(width: 400, height: 160))
        let view = try #require(scroll.documentView as? NSTextView)
        view.isEditable = false
        view.string = String(repeating: "error on line 42\n", count: 200)
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        view.scrollToBeginningOfDocument(nil)
        return (scroll, view)
    }
}
