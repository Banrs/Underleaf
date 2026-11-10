import AppKit

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
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var open: Int? { didSet { needsDisplay = true } }
    private var focused = 0 { didSet { noteFocusRingMaskChanged() } }
    private var watch: [NotificationCenter.ObservationToken] = []

    init(choose: @escaping (_ item: Int, _ choice: Int) -> Void) {
        self.choose = choose
        super.init(frame: .zero)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect,
                                                              .enabledDuringMouseDrag], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let chevron = symbol("chevron.compact.right", 11), popUp = symbol("chevron.up.chevron.down", 8)

    private static func symbol(_ name: String, _ size: CGFloat) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: size, weight: .medium))!
    }

    override var isFlipped: Bool { true }

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
        setAccessibilityChildren(zip(items, frames).enumerated().map { index, part in
            Part(parent: self, frame: part.1, value: part.0.choices[part.0.chosen]) { [weak self] in self?.popUp(index) }
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = inDarkAppearance
        let active = window?.isMainWindow == true, dimmed: NSColor = dark ? .secondaryLabelColor : .tertiaryLabelColor
        for (index, (item, frame)) in zip(items, frames).enumerated() {
            let lit = index == hovered || index == open
            if lit {
                // As in Xcode, the highlight covers the item's 17 pt pop-up, 1 pt inside the 19 pt row.
                (dark ? NSColor.white : .black).withAlphaComponent(0.05).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            let color: NSColor = item.chosen != 0 ? .controlAccentColor : active ? .labelColor : dimmed
            let title = NSAttributedString(string: item.choices[item.chosen], attributes: [.font: Self.font, .foregroundColor: color])
            title.draw(at: NSPoint(x: frame.minX + (index == 0 ? 7 : 2), y: frame.midY - title.size().height / 2))
            guard lit || index < items.count - 1 else { continue }
            let tint: NSColor = lit ? .labelColor : !active ? dimmed : dark ? .labelColor : .secondaryLabelColor
            let mark = lit ? Self.popUp : Self.chevron, size = mark.size
            let place = NSRect(x: frame.maxX - 7 - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            mark.withSymbolConfiguration(mark.symbolConfiguration.applying(.init(hierarchicalColor: tint)))?.draw(in: place)
        }
    }

    override func viewWillMove(toWindow window: NSWindow?) {
        watch = []
        guard let window else { return }
        watch = [
            NotificationCenter.default.addObserver(of: window, for: .didBecomeMain) { [weak self] _ in self?.needsDisplay = true },
            NotificationCenter.default.addObserver(of: window, for: .didResignMain) { [weak self] _ in self?.needsDisplay = true },
        ]
    }

    private func item(at point: NSPoint) -> Int? { frames.firstIndex { $0.contains(convert(point, from: nil)) } }

    override func mouseEntered(with event: NSEvent) { hovered = item(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hovered = item(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let index = item(at: event.locationInWindow) { popUp(index) }
    }

    private func popUp(_ index: Int) {
        let item = items[index], menu = NSMenu()
        menu.font = Self.font
        menu.autoenablesItems = false
        for (choice, title) in item.choices.enumerated() {
            let entry = menu.addItem(withTitle: title, action: #selector(chose(_:)), keyEquivalent: "")
            (entry.target, entry.tag, entry.representedObject) = (self, choice, index)
        }
        open = index
        let part = (accessibilityChildren() as? [NSAccessibilityElement])?[index]
        part?.setAccessibilityChildren([menu])
        defer { part?.setAccessibilityChildren(nil) }
        let place = NSPoint(x: frames[index].minX - 12 + (index == 0 ? 5 : 0), y: frames[index].midY - 11)
        menu.popUp(positioning: menu.item(at: item.chosen), at: place, in: self)
        open = nil
        hovered = window.flatMap { self.item(at: $0.mouseLocationOutsideOfEventStream) }
    }

    @objc private func chose(_ entry: NSMenuItem) {
        guard let index = entry.representedObject as? Int, entry.tag != items[index].chosen else { return }
        choose(index, entry.tag)
    }

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
            // Opened after the press returns, as a pop-up button's menu is, not while tracking.
            Task { @MainActor [press] in press() }
            return true
        }
    }
}
