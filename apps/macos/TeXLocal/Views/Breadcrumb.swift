import AppKit

/// Xcode's breadcrumb, the DVTPathControl its Find navigator builds: small, choosing one component at a time from a menu of
/// its peers. Drawn as DVTPathComponentCell draws, read from its code and compared with it rendered off-screen, since
/// NSPathControl draws another chevron, gap and gray: each item 2 pt in (7 for the first), its title in 11 pt, then 14 pt
/// with the chevron centred in it, none after the last. The item under the pointer gets a rect as tall as the control, at
/// most 21 pt, with 4 pt corners, filled with 5% of black or white, and its chevron becomes an up and down one, also after
/// the last item.
final class Breadcrumb: NSView {
    struct Item: Equatable {
        var choices: [String]
        var chosen: Int
    }

    var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            invalidateIntrinsicContentSize()
            (needsLayout, needsDisplay) = (true, true)
        }
    }

    private let choose: (_ item: Int, _ choice: Int) -> Void
    private var frames: [NSRect] = []
    private var hovered: Int?
    /// The item whose menu is open, which stays highlighted, as Xcode's pathCellItemForDisplayedPopover does.
    private var open: Int?
    private var focused = 0 { didSet { noteFocusRingMaskChanged() } }
    private var watch: [any NSObjectProtocol] = []

    init(choose: @escaping (_ item: Int, _ choice: Int) -> Void) {
        self.choose = choose
        super.init(frame: .zero)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// Xcode's chevrons, centred in the 14 pt after a title; its up and down one is DVTKit's own chevrons.popup, for which
    /// this is SF's, as wide in ink.
    private static let chevron = symbol("chevron.compact.right", 11), popUp = symbol("chevron.up.chevron.down", 8)

    private static func symbol(_ name: String, _ size: CGFloat) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: size, weight: .medium))!
    }

    override var isFlipped: Bool { true }

    // DVTPathControl accepts focus through the key-view loop, not a click that would take focus from Find's field.
    override var acceptsFirstResponder: Bool {
        guard let window else { return false }
        return !items.isEmpty && (window.firstResponder === self || window.keyViewSelectionDirection != .directSelection)
    }

    override func becomeFirstResponder() -> Bool {
        guard !items.isEmpty else { return false }
        focused = window?.keyViewSelectionDirection == .selectingPrevious ? items.count - 1 : 0
        return super.becomeFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { frames.indices.contains(focused) ? frames[focused] : .zero }
    override func drawFocusRingMask() { focusRingMaskBounds.fill() }

    private func moveFocus(_ step: Int) -> Bool {
        guard items.indices.contains(focused + step) else { return false }
        focused += step
        return true
    }

    @objc func selectNextKeyView(_ sender: Any?) {
        if !moveFocus(1) { window?.selectKeyView(following: self) }
    }

    @objc func selectPreviousKeyView(_ sender: Any?) {
        if !moveFocus(-1) { window?.selectKeyView(preceding: self) }
    }

    override func insertTab(_ sender: Any?) { selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { selectPreviousKeyView(sender) }
    override func moveLeft(_ sender: Any?) { _ = moveFocus(-1) }
    override func moveRight(_ sender: Any?) { _ = moveFocus(1) }
    override func moveDown(_ sender: Any?) { if items.indices.contains(focused) { popUp(focused) } }
    override func moveUp(_ sender: Any?) { moveDown(sender) }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r": moveDown(nil)
        default: interpretKeyEvents([event])
        }
    }

    /// As tall as Xcode's in its Find navigator.
    override var intrinsicContentSize: NSSize { NSSize(width: widths().reduce(0, +), height: 19) }

    private func widths() -> [CGFloat] {
        items.enumerated().map { index, item in
            let title = (item.choices[item.chosen] as NSString).size(withAttributes: [.font: Self.font]).width
            return ((index == 0 ? 7 : 2) + title + 14).rounded(.up)
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        frames = widths().map { width in
            defer { x += width }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
        updateTrackingAreas()
        setAccessibilityChildren(zip(items, frames).enumerated().map { index, part in
            Part(parent: self, frame: part.1, value: part.0.choices[part.0.chosen]) { [weak self] in self?.popUp(index) }
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Xcode dims the breadcrumb outside the main window, as its cells check the window before choosing colours.
        let active = window?.isMainWindow == true, dimmed: NSColor = dark ? .secondaryLabelColor : .tertiaryLabelColor
        for (index, (item, frame)) in zip(items, frames).enumerated() {
            let lit = index == hovered || index == open
            if lit {
                (dark ? NSColor.white : .black).withAlphaComponent(0.05).setFill()
                let height = min(frame.height, 21)
                let rect = NSRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            // As Xcode's Find navigator colours its components: the accent colour only off the first, default choice.
            let color: NSColor = item.chosen != 0 ? .controlAccentColor : active ? .labelColor : dimmed
            let title = NSAttributedString(string: item.choices[item.chosen], attributes: [.font: Self.font, .foregroundColor: color])
            title.draw(at: NSPoint(x: frame.minX + (index == 0 ? 7 : 2), y: frame.midY - title.size().height / 2))
            guard lit || index < items.count - 1 else { continue }
            let tint: NSColor = lit ? .labelColor : !active ? dimmed : dark ? .labelColor : .secondaryLabelColor
            let mark = lit ? Self.popUp : Self.chevron, size = mark.size
            let place = NSRect(x: frame.maxX - 7 - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            // Filled through the symbol's shape, as Xcode tints its chevrons, since a palette colour draws a lighter one.
            NSImage(size: mark.size, flipped: false) { rect in
                mark.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceIn)
                return true
            }.draw(in: place)
        }
    }

    override func viewWillMove(toWindow window: NSWindow?) {
        watch.forEach(NotificationCenter.default.removeObserver)
        watch = [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        }
    }

    /// One area an item, tracked as Xcode's path control tracks them: whether or not the window is key, and during drags.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        for (index, frame) in frames.enumerated() {
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag]
            if index == itemUnderMouse { options.insert(.assumeInside) }
            addTrackingArea(NSTrackingArea(rect: frame, options: options, owner: self, userInfo: ["index": index]))
        }
    }

    private var itemUnderMouse: Int? {
        guard let window else { return nil }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return frames.firstIndex { $0.contains(mouse) }
    }

    override func mouseEntered(with event: NSEvent) { hover(event.trackingArea?.userInfo?["index"] as? Int) }

    override func mouseExited(with event: NSEvent) {
        if hovered == event.trackingArea?.userInfo?["index"] as? Int { hover(nil) }
    }

    private func hover(_ index: Int?) {
        hovered = index
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = frames.firstIndex(where: { $0.contains(point) }) { popUp(index) }
    }

    /// Opens the item's menu in the breadcrumb's font, its choice over the item's title, where Xcode's path cell places it.
    private func popUp(_ index: Int) {
        let item = items[index], menu = NSMenu()
        menu.font = Self.font
        menu.autoenablesItems = false
        for (choice, title) in item.choices.enumerated() {
            let entry = menu.addItem(withTitle: title, action: #selector(chose(_:)), keyEquivalent: "")
            (entry.target, entry.tag, entry.representedObject) = (self, choice, index)
        }
        open = index
        needsDisplay = true
        // Its menu is the item's child while it's open, as Xcode's path control and a pop-up button give theirs.
        let part = (accessibilityChildren() as? [NSAccessibilityElement])?[index]
        part?.setAccessibilityChildren([menu])
        defer { part?.setAccessibilityChildren(nil) }
        let place = NSPoint(x: frames[index].minX - 12 + (index == 0 ? 5 : 0), y: frames[index].midY - 11)
        menu.popUp(positioning: menu.item(at: item.chosen), at: place, in: self)
        open = nil
        hover(itemUnderMouse)
    }

    @objc private func chose(_ entry: NSMenuItem) {
        guard let index = entry.representedObject as? Int, entry.tag != items[index].chosen else { return }
        choose(index, entry.tag)
    }

    /// Each item, to accessibility, a pop-up button, as Xcode lists its path control's components.
    private nonisolated final class Part: NSAccessibilityElement {
        private let press: @MainActor @Sendable () -> Void

        init(parent: NSView, frame: NSRect, value: String, press: @escaping @MainActor @Sendable () -> Void) {
            self.press = press
            super.init()
            setAccessibilityParent(parent)
            setAccessibilityRole(.popUpButton)
            setAccessibilityFrameInParentSpace(frame)
            setAccessibilityValue(value)
        }

        override func accessibilityPerformPress() -> Bool {
            // The menu opens after the press returns, as a pop-up button's does, rather than tracking inside the request.
            Task { @MainActor [press] in press() }
            return true
        }
    }
}
