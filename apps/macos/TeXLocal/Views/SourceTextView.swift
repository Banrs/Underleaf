import AppKit

final class SourceTextView: NSTextView, NSTextStorageDelegate, NSAccessibilityCustomRotorItemSearchDelegate {
    static let bandTrailingInset: CGFloat = 8
    static let bandRadius: CGFloat = 4
    static func plainDocument() -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.usesRuler = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.delegate = view
        (view.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = view
        view.installColouring()
        view.applyFont()
        view.displayOptionsWatch = NSWorkspace.shared.notificationCenter.addObserver(
            of: NSWorkspace.self, for: .accessibilityDisplayOptionsDidChange) { [weak view] _ in view?.needsDisplay = true }
        return view
    }

    private var displayOptionsWatch: NotificationCenter.ObservationToken?

    var document = SourceDocument(text: "") { willSet { document.composing = false } }
    var source: NSString { textStorage?.mutableString ?? "" }
    var undo = UndoManager()
    var fileDrop: (URL) -> FileDrop? = { _ in nil }
    enum FileDrop { case open(() -> Void), insert(String), copy(() async -> String?) }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }
    var openDefinition: (FilePlace) -> Void = { _ in }
    var quickHelp: (_ offset: Int, _ hovering: Bool) -> Void = { _, _ in }
    private(set) var loading = false

    func show(_ text: String) {
        loading = true
        sync = EditSync()
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        issues.place()
        inputContext?.discardMarkedText()
        unmarkText()
        folds = FoldSet()
        foldCache = nil
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        dismissedMath = nil
        _ = document.endSnippet()
        completions.close()
        hoverHelp.close()
        mark(nil)
        updateGutterWidth()
        staleColours = 0
    }

    var sync = EditSync()

    var fontSize = NSFont.systemFontSize { didSet { if fontSize != oldValue { applyFont() } } }
    var fontName = "" { didSet { if fontName != oldValue { applyFont() } } }
    private var applied: NSFont?

    private func applyFont() {
        let font = Self.font(named: fontName, size: fontSize, dark: inDarkAppearance)
        guard font != applied else { return }
        let resized = applied?.pointSize != font.pointSize || applied?.familyName != font.familyName
        applied = font
        let top = shownTop
        defer {
            top.map(scroll(toShownTop:))
            if !issues.isEmpty {
                Task { [weak self] in self?.textLayoutManager?.textViewportLayoutController.layoutViewport() }
            }
        }
        self.font = font
        completions.close()
        typingAttributes[.font] = font
        guard resized else { return }
        let style = Self.rowStyle(for: font)
        defaultParagraphStyle = style
        textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: length))
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
        gutter.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        issues.fontChanged(size: fontSize, text: font)
        updateGutterWidth()
    }

    /// Rows spaced by the 1.1× leading of Xcode's default themes, as line spacing so the caret keeps its native height.
    static func rowStyle(for font: NSFont) -> NSMutableParagraphStyle {
        let rowHeight = NSLayoutManager().defaultLineHeight(for: font)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = (rowHeight * 1.1).rounded() - rowHeight
        // Xcode's default tab width of 4 columns, where AppKit's 28 pt stops fall between them.
        style.tabStops = []
        style.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        return style
    }

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let text = textContentStorage.textStorage?.attributedSubstring(from: range), text.length > 0,
              let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else { return nil }
        let string = text.string
        let indent = string.prefix { $0 == " " || $0 == "\t" }
        let trailing = issues.trailingInset(on: document.line(at: range.location))
        let blank = string.first?.isNewline == true && string.dropFirst().isEmpty
        guard blank || !indent.isEmpty || trailing > 0 else { return nil }
        let shown = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? defaultParagraphStyle ?? .default
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: shown]
        let width = { (text: String) in (text as NSString).size(withAttributes: attributes).width }
        // Measuring puts the style in attributed text, and a paragraph style mustn't change once it's there (changing the
        // measured one doubled the time to indent 2,000 lines), so the indents go on a copy made afterwards.
        let style = shown.mutableCopy() as! NSMutableParagraphStyle
        style.headIndent = min(width(String(indent)), 20 * width(" "))
        if trailing > 0 { style.tailIndent = -trailing }
        // TextKit includes line spacing in a blank row's caret. Put that space above the row instead.
        if blank {
            style.paragraphSpacingBefore = style.lineSpacing
            style.lineSpacing = 0
        }
        let paragraph = NSMutableAttributedString(attributedString: text)
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }

    static func font(named name: String, size: CGFloat, dark: Bool) -> NSFont {
        (name.isEmpty ? nil : NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: dark ? .medium : .regular)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFont()
    }

    var gutter = EditorGutter()
    var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []
    var laidOut: () -> Void = {}
    var showsLineNumbers = true { didSet { if showsLineNumbers != oldValue { updateGutterWidth() } } }
    private(set) lazy var issues = IssueOverlay(in: self)
    var staleColours: Int?
    let fragmentColours = NSMapTable<NSTextLayoutFragment, NSArray>.weakToStrongObjects()
    var partnerMark: NSRange?
    var partnerDrawn: NSRect?
    var folds = FoldSet()
    var foldCache: [Int: Fold]?
    var foldMarks: [(rect: CGRect, range: NSRange)] = []
    var gutterHovered = false
    var stepping = false

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let current = selectedRange().length == 0 ? currentLine : nil
        drawCurrentLine(current, in: rect)
        issues.draw(in: rect, currentLine: current?.number)
        drawPartner(in: rect)
        drawNumbers(in: rect, current: current?.number)
        drawFolds(in: rect)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        issues.place()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !loading else { return }
        let shown = folds
        if let over = folds.moved(from: old, to: selectedRange(), stepping: stepping) {
            super.setSelectedRanges([NSValue(range: over)], affinity: affinity, stillSelecting: stillSelecting)
        }
        if folds != shown { relayOutFolds() }
        if !typing { completions.close() }
        if partnerMark != nil { mark(nil) }
        previewMath()
        document.select(selectedRange(), mirroring: sync.mirroring)
        redrawLineAndGutter()
    }

    var caret: Int { selectedRange().location }
    var selection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    var selections: [NSRange] { selectedRanges.map(\.rangeValue) }
    var length: Int { source.length }
    func word(at offset: Int) -> NSRange { selectionRange(forProposedRange: .caret(offset), granularity: .selectByWord) }

    var keyboardChanged: (Bool) -> Void = { _ in }

    private var keyWatches: [NotificationCenter.ObservationToken] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWatches = []
        guard let window else { return hoverHelp.close() }
        keyWatches = [
            NotificationCenter.default.addObserver(of: window, for: .didBecomeKey) { [weak self] _ in self?.keyChanged() },
            NotificationCenter.default.addObserver(of: window, for: .didResignKey) { [weak self] _ in self?.keyChanged() },
        ]
    }

    var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    private(set) lazy var mathPreview = MathPopover()
    var dismissedMath: Int?

    func previewMath() {
        let maths = loading ? nil : document.mathAt(caret: caret)
        if maths?.start != dismissedMath { dismissedMath = nil }
        guard hasKeyboard, let maths, dismissedMath == nil, enclosingScrollView != nil, let rect = popoverRect(at: caret),
              shownRect.contains(NSPoint(x: rect.minX, y: rect.midY)) else { return mathPreview.close() }
        mathPreview.show(maths, size: fontSize, at: rect, of: self, edge: completions.offered != nil && completions.isAbove ? .maxY : .minY)
    }

    override func becomeFirstResponder() -> Bool {
        defer { Task { self.previewMath() } }
        guard super.becomeFirstResponder() else { return false }
        keyboardChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer {
            mathPreview.close()
            completions.close()
        }
        guard super.resignFirstResponder() else { return false }
        keyboardChanged(false)
        return true
    }

    func keyChanged() {
        if !hasKeyboard { completions.close() }
        previewMath()
    }

    func rect(of range: NSRange) -> NSRect? {
        guard let window else { return nil }
        return convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
    }

    lazy var helpPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        return popover
    }()

    private(set) lazy var hoverHelp = HoverHelp(for: self)

    var autoPair = true, autoComplete = true
    var spellCheckToggled: (Bool) -> Void = { _ in }
    var typing = false

    private(set) lazy var completions = CompletionList(for: self)

    var mirrorHeld = false

    var headings: () -> [(line: Int, title: String)] = { [] }
    private lazy var rotors = [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self),
                               NSAccessibilityCustomRotor(label: String(localized: "Issues"), itemSearchDelegate: self)]

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { rotors }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor search: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let current = search.currentItem.map { document.line(at: min($0.targetRange.location, length)) }
        guard let found = rotorItem(issues: rotor.type != .heading, from: current, next: search.searchDirection == .next,
                                    filter: search.filterString) else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = found.range
        result.customLabel = found.title
        return result
    }

    private func rotorItem(issues listed: Bool, from line: Int?, next: Bool, filter: String = "") -> (range: NSRange, title: String)? {
        var items = !listed ? headings() : Set(issues.lines.keys).union(issues.live.keys).sorted().compactMap { line in
            issues.issue(on: line).map { issue, live in
                let place = live ? String(localized: "Live Preview error on line \(line)")
                    : issue.error ? String(localized: "Error on line \(line)") : String(localized: "Warning on line \(line)")
                return (line, String(localized: "\(place): \(issue.message.text)"))
            }
        }
        if !filter.isEmpty { items = items.filter { $0.title.localizedCaseInsensitiveContains(filter) } }
        guard let found = next ? items.first(where: { $0.line > line ?? 0 }) : items.last(where: { $0.line < line ?? .max })
        else { return nil }
        return (source.lineRange(for: .caret(min(document.lineStart(found.line), length))), found.title)
    }
}
