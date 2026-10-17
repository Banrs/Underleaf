import AppKit
import SwiftUI

extension SourceTextView {
    struct LineIssue: Equatable {
        var isError: Bool
        var message: String
        /// The core's line-end form of it.
        var short: String
        /// An undefined command's, in fewer words that keep its name.
        var compact: String?
        /// Where the line has the undefined command, from the line's start: underlined.
        var tokens: [NSRange] = []
        var others: [String] = []
    }

    /// A line's issue as placed: its band, the box at the line's end where it has room, and the underlines.
    struct IssueRow {
        let line: Int
        let isError: Bool
        let band: NSRect
        let shape: NSBezierPath
        var message: (view: IssueMessageView, rect: NSRect, cut: Bool)?
        var tip: String?
        /// The undefined command's underlines, where the line has it.
        var tokens: [NSRect] = []
    }
}

/// The build's issues on the lines laid out: a band over each paragraph with one, a box at the end of its first line
/// (`IssueBox`), help tags for words the box doesn't show, and the undefined command underlined. Placed again on each
/// layout, keeping each line's box.
final class IssueOverlay {
    private unowned let view: SourceTextView

    init(in view: SourceTextView) {
        self.view = view
    }

    var lines: [Int: SourceTextView.LineIssue] = [:] {
        didSet {
            guard lines != oldValue else { return }
            labels.removeAll()
            place()
            view.redrawLineAndGutter()
        }
    }

    private(set) var rows: [SourceTextView.IssueRow] = []
    /// The messages as measured, by line: for these issues and this font.
    private var labels: [Int: IssueLabel] = [:]
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)
    /// A character's width of the text's font: the least room between a line's text and its box.
    private var gap: CGFloat = 0
    private var tips: [(tag: NSView.ToolTipTag, rect: NSRect, text: NSString)] = []

    /// The message's font is the text's size; the gap a character of the text's font.
    func fontChanged(size: CGFloat, text: NSFont) {
        font = .systemFont(ofSize: size)
        gap = ("0" as NSString).size(withAttributes: [.font: text]).width
        labels.removeAll()
    }

    func place() {
        guard !lines.isEmpty || !rows.isEmpty else { return }
        var former = Dictionary(rows.map { ($0.line, $0) }) { $1 }
        rows.removeAll()
        func place(_ number: Int, on fragment: NSTextLayoutFragment, extra: Bool = false) {
            guard let reported = lines[number] else { return }
            let before = former.removeValue(forKey: number)
            // The document's last empty line is the last of the lines of the paragraph before it.
            var lines = fragment.textLineFragments[...]
            if extra { lines = lines.suffix(1) } else if view.extraLine(of: fragment) != nil { lines = lines.dropLast() }
            let placed = row(number, reported, on: lines, of: fragment, in: before?.message?.view)
            if let before {
                if before.band != placed?.band { view.setNeedsDisplay(before.band) }
                if before.message?.view !== placed?.message?.view { before.message?.view.removeFromSuperview() }
            }
            guard let placed else { return }
            if before?.band != placed.band || before?.tokens != placed.tokens { view.setNeedsDisplay(placed.band) }
            rows.append(placed)
        }
        for (offset, fragment) in view.fragments {
            let number = view.document.line(at: offset)
            place(number, on: fragment)
            if lines[number + 1] != nil, view.extraLine(of: fragment) != nil { place(number + 1, on: fragment, extra: true) }
        }
        for gone in former.values {
            view.setNeedsDisplay(gone.band)
            gone.message?.view.removeFromSuperview()
        }
        updateTips()
    }

    private func row(_ number: Int, _ reported: SourceTextView.LineIssue, on lines: ArraySlice<NSTextLineFragment>,
                     of fragment: NSTextLayoutFragment, in former: IssueMessageView?) -> SourceTextView.IssueRow? {
        guard let first = lines.first else { return nil }
        let band = view.band(lines, of: fragment)
        var issue = SourceTextView.IssueRow(line: number, isError: reported.isError, band: band,
                                            shape: NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4))
        // The fragment's lines in the view: its frame has the line fragment's padding in it.
        let left = view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX
        let top = view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        let said = [reported.message] + reported.others
        let label = labels[number] ?? IssueLabel(reported.short, compact: reported.compact, font: font)
        labels[number] = label
        typealias Metrics = IssueBox.Metrics
        let end = band.maxX - Metrics.endInset
        let room = end - (left + first.typographicBounds.maxX) - gap
        let issues = said.count
        let fitted = label.text(in: room - Metrics.width(ofText: 0, font: font, issues: issues))
        // A message cut short takes all the room there is, on whole points, as Xcode's does.
        let width = fitted?.cut == true ? room.rounded(.down) : Metrics.width(ofText: fitted?.width, font: font, issues: issues)
        if width <= room {
            let foot = view.onPixels(top + first.typographicBounds.maxY + view.rowShift)
            let rect = NSRect(x: end - width, y: band.minY, width: width, height: foot - band.minY)
            let box = IssueBox(isError: reported.isError, issues: issues, text: fitted?.text, cutAtTail: fitted != nil && fitted?.width == nil,
                               font: font, fill: Color(nsColor: view.backgroundColor),
                               baseline: top + first.typographicBounds.minY + first.glyphOrigin.y - rect.minY)
            let message = former ?? IssueMessageView(box)
            if message.rootView != box { message.rootView = box }
            if message.frame != rect { message.frame = rect }
            if message.superview !== view { view.addSubview(message) }
            issue.message = (message, rect, fitted?.cut ?? true)
        }
        if issue.message?.cut != false || said.count > 1 { issue.tip = said.joined(separator: "\n") }
        // Underlined in the system's red, as Xcode does an issue's token, under the text: TextKit 2 draws no underline
        // given as a rendering attribute (27.2).
        if !reported.tokens.isEmpty, let textFont = view.font {
            // As far under the baseline as the font puts an underline, a point thick at least, on whole pixels.
            let scale = view.window?.backingScaleFactor ?? 1
            func whole(_ length: CGFloat) -> CGFloat { (length * scale).rounded() / scale }
            let thickness = max(1, whole(textFont.underlineThickness))
            for range in reported.tokens {
                // A command a line is too narrow for is on two.
                for line in lines {
                    let part = NSIntersectionRange(range, line.characterRange)
                    guard part.length > 0 else { continue }
                    let lineLeft = left + line.typographicBounds.minX
                    let start = whole(lineLeft + line.locationForCharacter(at: part.location).x)
                    let end = whole(lineLeft + line.locationForCharacter(at: NSMaxRange(part)).x)
                    let under = top + line.typographicBounds.minY + line.glyphOrigin.y - textFont.underlinePosition
                    issue.tokens.append(NSRect(x: start, y: whole(under), width: end - start, height: thickness))
                }
            }
        }
        return issue
    }

    private func updateTips() {
        let wanted = rows.compactMap { row in row.tip.flatMap { tip in row.message.map { ($0.rect, tip) } } }
        guard !wanted.elementsEqual(tips, by: { $0.0 == $1.rect && $1.text.isEqual(to: $0.1) }) else { return }
        for tip in tips { view.removeToolTip(tip.tag) }
        // The string is the tag's owner, which AppKit asks for its description and doesn't keep.
        tips = wanted.map { rect, tip in
            let text = tip as NSString
            return (view.addToolTip(rect, owner: text, userData: nil), rect, text)
        }
    }

    /// The row whose box is under `point`, in the view's coordinates.
    func message(at point: NSPoint) -> SourceTextView.IssueRow? {
        guard !rows.isEmpty, view.visibleRect.contains(point) else { return nil }
        return rows.first { $0.message?.rect.contains(point) == true }
    }

    /// The bands and underlines in `rect`; the caret's line has the current line's fill, which is the same shape, and not both.
    func draw(in rect: NSRect, currentLine: Int?) {
        for issue in rows where issue.band.maxY >= rect.minY && issue.band.minY <= rect.maxY {
            if issue.line != currentLine {
                NSColor.tertiarySystemFill.setFill()
                issue.shape.fill()
            }
            NSColor.systemRed.setFill()
            issue.tokens.forEach { $0.fill() }
        }
    }
}
