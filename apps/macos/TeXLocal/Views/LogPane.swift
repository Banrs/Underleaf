import SwiftUI

struct LogPane: View {
    let text: String
    let filter: String
    let hiddenKinds: Set<LogKind>
    let title: String
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var filtered: String?

    var body: some View {
        let filtering = !filter.isEmpty || !hiddenKinds.isEmpty
        // Until a new filter's lines arrive, the last filter's stay, even if there were none.
        let shown = filtering ? filtered ?? text : text
        Group {
            if shown.isEmpty, filtering {
                ContentUnavailableView.search
            } else {
                GeometryReader { geometry in
                    // The editor's font, size and rows.
                    LogTextView(text: shown, title: title, bottomInset: geometry.safeAreaInsets.bottom,
                                font: SourceTextView.font(named: app.fontName, size: CGFloat(app.fontSize), dark: colorScheme == .dark))
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .task(id: [text, filter, hiddenKinds.map(\.title).sorted().joined(separator: ",")]) {
            guard filtering else { return filtered = nil }
            if let lines = await Self.lines(of: text, with: filter, hiding: hiddenKinds), !Task.isCancelled { filtered = lines }
        }
    }

    @concurrent private nonisolated static func lines(of text: String, with filter: String, hiding hidden: Set<LogKind>) async -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kinds = hidden.isEmpty ? nil : Syntax.call(LogKinds(log: text)).flatMap { $0.count == lines.count ? $0 : nil }
        var kept: [Substring] = []
        for (index, line) in lines.enumerated() {
            if Task.isCancelled { return nil }
            if let kinds, hidden.contains(kinds[index]) { continue }
            if filter.isEmpty || line.localizedCaseInsensitiveContains(filter) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}

struct LogTextView: NSViewRepresentable {
    let text: String
    let title: String
    let bottomInset: CGFloat
    let font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        // With the container's own padding, text starts 16 pt in, as in Xcode's console.
        view.textContainerInset = NSSize(width: 11, height: 8)
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        if view.font != font {
            let style = SourceTextView.rowStyle(for: font)
            view.font = font
            view.defaultParagraphStyle = style
            view.textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        }
        if scroll.contentInsets.bottom != bottomInset {
            let atEnd = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1
            scroll.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = bottomInset
            if atEnd { scrollToEnd(scroll, view) }
        }
        let shown = view.string
        guard shown != text else { return }
        let selections = view.selectedRanges.map(\.rangeValue)
        let origin = scroll.contentView.bounds.origin
        let followsTail = !scroll.isFindBarVisible && selections.allSatisfy { $0.length == 0 }
            && (shown.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1)
        let previousLength = (shown as NSString).length, new = text as NSString
        let added = previousLength > 0 && text.utf16.starts(with: shown.utf16)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: view.defaultParagraphStyle ?? .default,
                                                         .foregroundColor: NSColor.textColor]
        view.textStorage?.replaceCharacters(in: added ? .caret(previousLength) : NSRange(location: 0, length: previousLength),
                                            with: NSAttributedString(string: added ? new.substring(from: previousLength) : text, attributes: attributes))
        view.didChangeText()
        let length = new.length
        view.selectedRanges = selections.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        if followsTail {
            scrollToEnd(scroll, view)
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func scrollToEnd(_ scroll: NSScrollView, _ view: NSTextView) {
        view.scrollToEndOfDocument(nil)
        // SwiftUI may finish sizing the viewport after this update. Follow its final bottom inset too.
        Task { [weak scroll] in
            guard let scroll else { return }
            let clip = scroll.contentView
            var bottom = clip.bounds
            bottom.origin.y = clip.documentRect.maxY
            clip.scroll(to: clip.constrainBoundsRect(bottom).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
