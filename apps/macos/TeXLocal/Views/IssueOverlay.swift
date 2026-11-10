import AppKit
import SwiftUI

final class IssueOverlay {
    struct Row {
        let line: Int
        let error: Bool
        let live: Bool
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
        measured.removeAll()
        place()
        view.redrawLineAndGutter()
    }

    private(set) var rows: [Row] = []
    private var measured: [Int: [Fit]] = [:]
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)
    private lazy var sizer = NSHostingView(rootView: IssueBox(isError: true, isLive: false, issues: 1, text: nil, truncates: false, font: font))
    private var gap: CGFloat = 0
    private var tips: [(tag: NSView.ToolTipTag, rect: NSRect, text: NSString)] = []

    func fontChanged(size: CGFloat, text: NSFont) {
        font = .systemFont(ofSize: size)
        gap = ("0" as NSString).size(withAttributes: [.font: text]).width
        measured.removeAll()
    }

    func place() {
        guard !isEmpty || !rows.isEmpty else { return }
        var views = Dictionary(rows.compactMap { row in row.message.map { (row.line, $0.view) } }) { $1 }
        rows.forEach { view.setNeedsDisplay($0.band) }
        rows.removeAll()
        func place(_ number: Int, on fragment: NSTextLayoutFragment, extra: Bool = false) {
            guard let (reported, live) = issue(on: number) else { return }
            let former = views.removeValue(forKey: number)
            let placed = row(number, reported, live: live, on: fragment.lines(extra: extra), of: fragment, in: former)
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

    private func row(_ number: Int, _ reported: IssueLine, live: Bool, on lines: ArraySlice<NSTextLineFragment>,
                     of fragment: NSTextLayoutFragment, in former: IssueMessageView?) -> Row? {
        guard let first = lines.first else { return nil }
        let band = view.band(lines, of: fragment)
        var issue = Row(line: number, error: reported.error, live: live, band: band)
        let left = view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX
        let top = view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        let said = ([reported.message] + reported.others).map(\.text)
        let room = (band.maxX - (left + first.typographicBounds.maxX) - gap).rounded(.down)
        if let fit = fits(number, reported, live: live, issues: said.count).first(where: { $0.width <= room }) {
            let width = fit.box.truncates ? room : fit.width
            let foot = view.onPixels(top + first.typographicBounds.maxY)
            let rect = CGRect(x: band.maxX - width, y: band.minY, width: width, height: foot - band.minY)
            let message = former ?? IssueMessageView(fit.box)
            if message.rootView != fit.box { message.rootView = fit.box }
            if message.frame != rect { message.frame = rect }
            if message.superview !== view { view.addSubview(message) }
            issue.message = (message, rect, fit.cut)
        }
        if issue.message?.cut != false || said.count > 1 { issue.tip = said.joined(separator: "\n") }
        if !reported.tokens.isEmpty, let textFont = view.font {
            let thickness = max(1, view.onPixels(textFont.underlineThickness))
            for token in reported.tokens {
                for line in lines {
                    let part = NSIntersectionRange(token.range, line.characterRange)
                    guard part.length > 0 else { continue }
                    let lineLeft = left + line.typographicBounds.minX
                    let start = view.onPixels(lineLeft + line.locationForCharacter(at: part.location).x)
                    let end = view.onPixels(lineLeft + line.locationForCharacter(at: NSMaxRange(part)).x)
                    let under = top + line.typographicBounds.minY + line.glyphOrigin.y - textFont.underlinePosition
                    issue.tokens.append(CGRect(x: start, y: view.onPixels(under), width: end - start, height: thickness))
                }
            }
        }
        return issue
    }

    private struct Fit {
        let box: IssueBox
        let width: CGFloat
        let cut: Bool
    }

    private func fits(_ number: Int, _ reported: IssueLine, live: Bool, issues: Int) -> [Fit] {
        if let found = measured[number] { return found }
        func box(_ text: String?, truncates: Bool = false) -> IssueBox {
            IssueBox(isError: reported.error, isLive: live, issues: issues, text: text, truncates: truncates, font: font)
        }
        func fit(_ box: IssueBox, cut: Bool, measuring shown: IssueBox? = nil) -> Fit {
            sizer.rootView = shown ?? box
            return Fit(box: box, width: sizer.fittingSize.width.rounded(.up), cut: cut)
        }
        let whole = reported.short.text, compact = reported.compact?.text
        var found = [fit(box(whole), cut: false)]
        if let compact { found.append(fit(box(compact), cut: true)) }
        let most = (compact ?? whole) as NSString
        let least = most.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(10, most.length)))
        if least.length >= 10 {
            let shown = most.substring(with: least).trimmingCharacters(in: .whitespaces) + "…"
            found.append(fit(box(most as String, truncates: true), cut: true, measuring: box(shown)))
        }
        found.append(fit(box(nil), cut: true))
        measured[number] = found
        return found
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
                IssueBox.line(error: issue.error, live: issue.live).setFill()
                NSBezierPath(roundedRect: issue.band, xRadius: 4, yRadius: 4).fill()
            }
            IssueBox.underlines[issue.error]?.setFill()
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
