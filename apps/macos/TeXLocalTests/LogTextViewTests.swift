import AppKit
import Testing
@testable import TeXLocal

@MainActor
struct LogTextViewTests {
    @Test func liveOutputKeepsTheSelectedErrorAndReadingPosition() {
        let scroll = logScroll()
        let view = scroll.documentView as! NSTextView
        let initial = view.string
        let selection = NSRange(location: 12, length: 8)
        view.setSelectedRange(selection)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)

        LogTextView(text: initial + "new output\n").updateText(in: scroll)
        #expect(view.selectedRange() == selection)
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(view.string == initial + "new output\n")

        // A restart or bounded-log rollover can replace everything, including
        // shortening past the selected error. That must not crash AppKit.
        LogTextView(text: "é\n").updateText(in: scroll)
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
        LogTextView(text: "e\u{301}\nnext\n").updateText(in: scroll)
        #expect(view.string.utf16.elementsEqual("e\u{301}\nnext\n".utf16))
    }

    @Test func findStopsFollowingTheLiveTail() {
        let scroll = logScroll()
        let view = scroll.documentView as! NSTextView
        scroll.findBarView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        scroll.isFindBarVisible = true
        view.scrollToEndOfDocument(nil)
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)
        LogTextView(text: view.string + String(repeating: "more output\n", count: 50)).updateText(in: scroll)
        #expect(scroll.contentView.bounds.origin == origin)

        scroll.isFindBarVisible = false
        view.scrollToEndOfDocument(nil)
        let end = scroll.contentView.bounds.origin.y
        LogTextView(text: view.string + String(repeating: "more output\n", count: 50)).updateText(in: scroll)
        #expect(scroll.contentView.bounds.origin.y > end)
    }

    private func logScroll() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.setFrameSize(NSSize(width: 400, height: 160))
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.string = String(repeating: "error on line 42\n", count: 200)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.scrollToBeginningOfDocument(nil)
        return scroll
    }
}
