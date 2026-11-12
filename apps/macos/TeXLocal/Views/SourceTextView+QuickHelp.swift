import AppKit
import SwiftUI

/// Quick Help for the reference or citation the pointer rests on: shown after a pause, and closed once the pointer
/// leaves both the key and the popover, or on a key press, click or scroll.
final class HoverHelp {
    private unowned let text: SourceTextView
    private let popover = NSPopover()
    private var resting: Task<Void, Never>?
    private var monitor: Any?
    /// The key the pointer rests on, in the text view's coordinates.
    private var anchor: (range: NSRange, rect: NSRect)?

    init(for text: SourceTextView) {
        self.text = text
        popover.behavior = .applicationDefined
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func moved(to point: NSPoint) {
        if let anchor, anchor.rect.contains(point) { return }
        close()
        restart(&resting, after: .milliseconds(500)) { [weak self] in self?.rested() }
    }

    /// Leaving the text view for the popover keeps it.
    func exited() {
        if popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) != true { close() }
    }

    private func rested() {
        // A key pressed since the pointer stopped means it rests by chance while typing.
        guard let window = text.window, window.isKeyWindow,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 0.5,
              let key = text.referenceKey(at: text.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        anchor = key
        text.quickHelp(key.range.location, true)
    }

    /// Shows help that was asked for at `offset`, if the pointer is still on its key.
    func show(_ content: NSViewController, at offset: Int) {
        guard let anchor, NSLocationInRange(offset, anchor.range), text.window?.isVisible == true else { return }
        popover.contentViewController = content
        popover.show(relativeTo: anchor.rect, of: text, preferredEdge: .maxY)
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown,
                                                                         .scrollWheel]) { [weak self] event in
            self?.heard(event)
            return event
        }
    }

    private func heard(_ event: NSEvent) {
        let inPopover = popover.contentViewController?.view.window.map { $0.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) }
        switch event.type {
        case .mouseMoved where inPopover == true: break
        case .mouseMoved where event.window === text.window:
            if let anchor, !anchor.rect.contains(text.convert(event.locationInWindow, from: nil)) { close() }
        case .leftMouseDown, .rightMouseDown: if inPopover != true { close() }
        default: close()
        }
    }

    func close() {
        resting?.cancel()
        resting = nil
        anchor = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if popover.isShown { popover.close() }
    }
}

extension SourceTextView {
    /// The label or citation key under `point`, if the pointer is on its text.
    func referenceKey(at point: NSPoint) -> (range: NSRange, rect: NSRect)? {
        guard window != nil, point.x >= textContainerOrigin.x else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard let at = [index, index - 1].first(where: { $0 >= 0 && $0 < length && rect(of: NSRange(location: $0, length: 1))?.contains(point) == true }),
              let range = document.reference(at: at), let rect = rect(of: range) else { return nil }
        return (range, rect.insetBy(dx: -2, dy: -2))
    }

    func popoverRect(at offset: Int) -> NSRect? {
        guard var rect = rect(of: .caret(offset)) else { return nil }
        rect.size.width = max(rect.width, 1)
        return rect
    }

    func showQuickHelp(_ help: QuickHelp, picture: ReferencePicture?, at offset: Int, hovering: Bool) {
        let bold = NSFontManager.shared.convert(font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular), toHaveTrait: .boldFontMask)
        let content = NSHostingController(rootView: QuickHelpView(help: help, picture: picture, font: bold) { [weak self] place in
            self?.helpPopover.close()
            self?.hoverHelp.close()
            self?.openDefinition(place)
        })
        content.sizingOptions = .preferredContentSize
        if hovering { return helpPopover.isShown ? () : hoverHelp.show(content, at: offset) }
        guard let rect = popoverRect(at: offset) else { return }
        hoverHelp.close()
        helpPopover.contentViewController = content
        helpPopover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }
}
