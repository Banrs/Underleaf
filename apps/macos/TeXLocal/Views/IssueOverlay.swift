import AppKit
import SwiftUI

final class IssueOverlay {
    struct Row {
        let line: Int
        let error: Bool
        let band: CGRect
        var message: (view: IssueMessageView, rect: CGRect, cut: Bool)?
        var tip: String?
        var tokens: [CGRect] = []
    }

    private unowned let view: SourceTextView

    init(in view: SourceTextView) { self.view = view }

    var lines: [Int: IssueLine] = [:] { didSet { if lines != oldValue { changed() } } }
    var live: [Int: IssueLine] = [:] { didSet { if live != oldValue { changed() } } }
    var isEmpty: Bool { lines.isEmpty && live.isEmpty }
    var clicked: (Int) -> Void = { _ in }

    func issue(on number: Int) -> (issue: IssueLine, live: Bool)? {
        lines[number].map { ($0, false) } ?? live[number].map { ($0, true) }
    }

    private func changed() {
        labels.removeAll()
        place()
        view.redrawLineAndGutter()
    }

    private(set) var rows: [Row] = []
    private var labels: [Int: IssueLabel] = [:]
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)
    private var gap: CGFloat = 0
    private var tips: [(tag: NSView.ToolTipTag, rect: NSRect, text: NSString)] = []

    func fontChanged(size: CGFloat, text: NSFont) {
        font = .systemFont(ofSize: size)
        gap = ("0" as NSString).size(withAttributes: [.font: text]).width
        labels.removeAll()
    }

    func place() {
        guard !isEmpty || !rows.isEmpty else { return }
        var views = Dictionary(rows.compactMap { row in row.message.map { (row.line, $0.view) } }) { $1 }
        rows.forEach { view.setNeedsDisplay($0.band) }
        rows.removeAll()
        func place(_ number: Int, on fragment: NSTextLayoutFragment, extra: Bool = false) {
            guard let reported = issue(on: number)?.issue else { return }
            let former = views.removeValue(forKey: number)
            let placed = row(number, reported, on: fragment.lines(extra: extra), of: fragment, in: former)
            if placed?.message?.view !== former { former?.removeFromSuperview() }
            guard let placed else { return }
            view.setNeedsDisplay(placed.band)
            rows.append(placed)
        }
        for (offset, fragment) in view.fragments {
            let number = view.document.line(at: offset)
            place(number, on: fragment)
            if issue(on: number + 1) != nil, fragment.extraLine != nil { place(number + 1, on: fragment, extra: true) }
        }
        views.values.forEach { $0.removeFromSuperview() }
        updateTips()
    }

    private func row(_ number: Int, _ reported: IssueLine, on lines: ArraySlice<NSTextLineFragment>,
                     of fragment: NSTextLayoutFragment, in former: IssueMessageView?) -> Row? {
        guard let first = lines.first else { return nil }
        let band = view.band(lines, of: fragment)
        var issue = Row(line: number, error: reported.error, band: band)
        let left = view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX
        let top = view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        let said = ([reported.message] + reported.others).map(\.text)
        let label = labels[number] ?? IssueLabel(reported.short.text, compact: reported.compact?.text, font: font)
        labels[number] = label
        typealias Metrics = IssueBox.Metrics
        let end = band.maxX
        let room = end - (left + first.typographicBounds.maxX) - gap
        let issues = said.count
        let fitted = label.text(in: room - Metrics.width(ofText: 0, font: font, issues: issues))
        let width = fitted?.cut == true ? room.rounded(.down) : Metrics.width(ofText: fitted?.width, font: font, issues: issues)
        if width <= room {
            let foot = view.onPixels(top + first.typographicBounds.maxY + view.rowShift)
            let rect = CGRect(x: end - width, y: band.minY, width: width, height: foot - band.minY)
            let fill = Color(nsColor: view.backgroundColor)
            let box = IssueBox(isError: reported.error, issues: issues, text: fitted?.text,
                               cutAtTail: fitted != nil && fitted?.width == nil, font: font, fill: fill,
                               baseline: top + first.typographicBounds.minY + first.glyphOrigin.y - rect.minY)
            let message = former ?? IssueMessageView(box)
            if message.rootView != box { message.rootView = box }
            if message.frame != rect { message.frame = rect }
            if message.superview !== view { view.addSubview(message) }
            issue.message = (message, rect, fitted?.cut ?? true)
        }
        if issue.message?.cut != false || issues > 1 { issue.tip = said.joined(separator: "\n") }
        if !reported.tokens.isEmpty, let textFont = view.font {
            let thickness = max(1, view.onPixels(CTFontGetUnderlineThickness(textFont as CTFont)))
            for token in reported.tokens {
                for line in lines {
                    let part = NSIntersectionRange(token.range, line.characterRange)
                    guard part.length > 0 else { continue }
                    let lineLeft = left + line.typographicBounds.minX
                    let start = view.onPixels(lineLeft + line.locationForCharacter(at: part.location).x)
                    let end = view.onPixels(lineLeft + line.locationForCharacter(at: NSMaxRange(part)).x)
                    let under = top + line.typographicBounds.minY + line.glyphOrigin.y - CTFontGetUnderlinePosition(textFont as CTFont)
                    issue.tokens.append(CGRect(x: start, y: view.onPixels(under), width: end - start, height: thickness))
                }
            }
        }
        return issue
    }

    private func updateTips() {
        let wanted = rows.compactMap { row in row.tip.flatMap { tip in row.message.map { ($0.rect, tip) } } }
        guard !wanted.elementsEqual(tips, by: { $0.0 == $1.rect && $1.text.isEqual(to: $0.1) }) else { return }
        for tip in tips { view.removeToolTip(tip.tag) }
        tips = wanted.map { rect, tip in
            let text = tip as NSString
            return (view.addToolTip(rect, owner: text, userData: nil), rect, text)
        }
    }

    func message(at point: NSPoint) -> Row? {
        view.visibleRect.contains(point) ? rows.first(where: { $0.message?.rect.contains(point) == true }) : nil
    }

    func draw(in rect: CGRect, currentLine: Int?) {
        for issue in rows where issue.band.maxY >= rect.minY && issue.band.minY <= rect.maxY {
            if issue.line != currentLine {
                IssueBox.tint(error: issue.error).setFill()
                NSBezierPath(roundedRect: issue.band, xRadius: 4, yRadius: 4).fill()
            }
            NSColor.systemRed.setFill()
            issue.tokens.forEach { $0.fill() }
        }
    }
}

final class IssueMessageView: NSHostingView<IssueBox> {
    convenience init(_ box: IssueBox) {
        self.init(rootView: box)
        sizingOptions = []
        safeAreaRegions = []
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
