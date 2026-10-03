import AppKit

/// Edit › Go to Line… as Xcode 27 has it, rather than a sheet with Cancel and Go: a field
/// on the system's glass in a panel of its own, centred on the screen a quarter of the way
/// down. Return goes to the line and closes it; text that isn't one of the file's lines
/// beeps and is selected to type over; Escape, or a click anywhere else, closes it.
final class GoToLinePanel: NSPanel, NSTextFieldDelegate {
    /// Xcode's, measured: the panel, its glass's corners, its type, and where the
    /// magnifying glass and the text start.
    static let size = NSSize(width: 640, height: 55)
    private static let cornerRadius: CGFloat = 24
    private static let fontSize: CGFloat = 22
    private static let symbolInset: CGFloat = 15, symbolWidth: CGFloat = 34
    private static let fieldInset: CGFloat = 65, trailingInset: CGFloat = 19

    let field = NSTextField()
    /// The line, from 1; false when the file has no such line.
    private let go: (Int) -> Bool
    /// The window the field was asked for from, which has the keyboard back after it.
    private weak var owner: NSWindow?
    private var dismissing = false

    init(go: @escaping (Int) -> Bool) {
        self.go = go
        // Titled, as Xcode's, for a window's shadow; its title bar and buttons out of sight.
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        // Not a document (HIG, Panels).
        isExcludedFromWindowsMenu = true
        title = String(localized: "Go to Line")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // The glass is the panel's shape.
        isOpaque = false
        backgroundColor = .clear
        setAccessibilitySubrole(.dialog)

        let symbol = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.fontSize, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setAccessibilityElement(false)

        let font = NSFont.systemFont(ofSize: Self.fontSize)
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: String(localized: "Line Number"),
                                                               attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        field.delegate = self

        let content = NSView()
        for view in [symbol, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.symbolInset),
            symbol.widthAnchor.constraint(equalToConstant: Self.symbolWidth),
            // Half a point low, as Xcode's.
            symbol.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 0.5),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.fieldInset),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.trailingInset),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = content
        contentView = glass
    }

    /// Empty, on the screen `window` is on, where Xcode puts it: centred, its top a
    /// quarter of the way down the screen's room (`NSScreen.visibleFrame`).
    func show(over window: NSWindow) {
        guard let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        owner = window
        appearance = window.appearance
        setFrameOrigin(NSPoint(x: (area.midX - frame.width / 2).rounded(.down),
                               y: (area.maxY - area.height / 4 - frame.height).rounded(.down)))
        field.stringValue = ""
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// Ordered out, not closed: the next Go to Line uses it again.
    func dismiss(returningKeyboard: Bool) {
        guard isVisible, !dismissing else { return }
        dismissing = true
        orderOut(nil)
        if returningKeyboard { owner?.makeKey() }
        dismissing = false
    }

    /// A click in another window, or another app.
    override func resignKey() {
        super.resignKey()
        dismiss(returningKeyboard: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            if let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), go(line) {
                dismiss(returningKeyboard: true)
            } else {
                NSSound.beep()
                textView.selectAll(nil)
            }
            return true
        case #selector(cancelOperation(_:)):
            dismiss(returningKeyboard: true)
            return true
        default:
            return false
        }
    }
}
