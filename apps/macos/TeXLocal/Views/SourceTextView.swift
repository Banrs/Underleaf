import AppKit
import SwiftUI

final class SourceTextView: NSTextView, NSTextStorageDelegate, NSAccessibilityCustomRotorItemSearchDelegate {
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
        lastMath = nil
        dismissedMath = nil
        _ = document.endSnippet()
        completions.close()
        hoverHelp.close()
        mark(nil)
        updateGutterWidth()
        staleColours = 0
    }

    private var sync = EditSync()

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard document.editable, super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else {
            return false
        }
        sync.willChange(affectedRanges.map(\.rangeValue), to: replacementStrings)
        return true
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        foldCache = nil
        let edits = sync.edited(edited, delta: delta, in: textStorage.mutableString, of: document)
        if !edits.filter({ folds.edited($0.range, delta: $0.text.utf16.count - $0.length) }).isEmpty { Task { self.relayOutFolds() } }
        lastMath = nil
        staleColours = min(staleColours ?? edited.location, edited.location)
        if gutter.digits != EditorGutter.digits(document.lineCount) { Task { self.updateGutterWidth() } }
    }

    /// Makes edits given front to back as one undo step, which undoes and redoes through here too, in one TextKit pass:
    /// NSTextView's own undo replays them one pass each, and took 6 s to undo an indent of 2,000 lines.
    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: [NSRange]? = nil) -> Bool {
        guard isEditable, document.editable, !edits.isEmpty else { return false }
        let selections = selecting ?? document.map(selectedRanges.map(\.rangeValue), through: edits)
        var shift = 0
        let undone = edits.map { edit in
            let range = NSRange(location: edit.range.location + shift, length: edit.text.utf16.count)
            shift += range.length - edit.range.length
            return TextEdit(range, source.substring(with: edit.range))
        }
        let restored = self.selections
        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { $0.apply(undone, named: name, selecting: restored) }
        undoManager?.disableUndoRegistration()
        replace(edits.reversed())
        undoManager?.enableUndoRegistration()
        if !selections.isEmpty { setSelectedRanges(selections.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false) }
        // The selections are set before mirroring, so the mirror's edits move them as typing's do.
        mirror()
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        scrollRangeToVisible(selectedRange())
        return true
    }

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
        let number = document.line(at: range.location)
        let trailing = issues.trailingInset(on: number)
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
        let whole = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.paragraphStyle, value: style, range: whole)
        // An issue's tokens underlined by TextKit, which breaks the line around descenders, as Xcode 27.2's does.
        if let (issue, _) = issues.issue(on: number), let colour = IssueBox.underlines[issue.error] {
            for token in issue.tokens {
                let part = NSIntersectionRange(NSRange(location: token.start, length: token.length), whole)
                if part.length > 0 {
                    paragraph.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: colour], range: part)
                }
            }
        }
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
    var lastMath: (caret: Int, value: MathPreview?)?
    var dismissedMath: Int?

    func previewMath() {
        let maths = loading ? nil : math(at: caret)
        if maths?.start != dismissedMath { dismissedMath = nil }
        guard hasKeyboard, let maths, dismissedMath == nil, enclosingScrollView != nil, let rect = popoverRect(at: caret),
              shownRect.contains(NSPoint(x: rect.minX, y: rect.midY)) else { return mathPreview.close() }
        mathPreview.show(maths, size: fontSize, at: rect, of: self, edge: completions.offered != nil && completions.isAbove ? .maxY : .minY)
    }

    private func popoverRect(at offset: Int) -> NSRect? {
        guard let window else { return nil }
        var rect = convert(window.convertFromScreen(firstRect(forCharacterRange: .caret(offset), actualRange: nil)), from: nil)
        rect.size.width = max(rect.width, 1)
        return rect
    }

    private lazy var helpPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        return popover
    }()

    private(set) lazy var hoverHelp = HoverHelp(for: self)

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

    override func moveRight(_ sender: Any?) { stepCaret(1) { super.moveRight(sender) } }
    override func moveLeft(_ sender: Any?) { stepCaret(-1) { super.moveLeft(sender) } }

    private func stepCaret(_ step: Int, by move: () -> Void) {
        let before = selectedRange()
        move()
        guard before.length == 0, selectedRange() == .caret(before.location + step) else { return }
        showPartner(of: min(before.location, before.location + step))
    }

    var autoPair = true, autoComplete = true
    var spellCheckToggled: (Bool) -> Void = { _ in }
    private var typing = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextChanged()
        mirror()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable else { return super.insertText(string, replacementRange: replacementRange) }
        let wasTyping = typing
        typing = true
        defer {
            typing = wasTyping
            markedTextChanged()
        }
        guard let typed = string as? String, replacementRange.location == NSNotFound, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return completions.close()
        }
        let stroke = document.type(typed, replacing: selectedRange(), autoPair: autoPair)
        holdingMirror {
            if let edit = stroke.edit {
                super.insertText(edit.text, replacementRange: edit.range)
            } else if stroke.selection == nil {
                super.insertText(string, replacementRange: replacementRange)
            }
        }
        finish(stroke)
    }

    override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return super.deleteBackward(sender) }
        let wasTyping = typing, completing = completions.offered != nil
        typing = true
        defer {
            typing = wasTyping
            if completing { completions.offer() }
        }
        guard selectedRanges.count == 1, let edit = document.deleteBackward(selectedRange(), autoPair: autoPair).edit
        else { return super.deleteBackward(sender) }
        super.insertText(edit.text, replacementRange: edit.range)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, selectedRanges.count == 1 else { return super.insertNewline(sender) }
        let stroke = document.insertNewline(selectedRange())
        guard let edit = stroke.edit else { return super.insertNewline(sender) }
        holdingMirror { super.insertText(edit.text, replacementRange: edit.range) }
        finish(stroke)
    }

    override func insertTab(_ sender: Any?) { isEditable ? tab(1) : super.insertTab(sender) }
    override func insertBacktab(_ sender: Any?) { isEditable ? tab(-1) : super.insertBacktab(sender) }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        spellCheckToggled(isContinuousSpellCheckingEnabled)
    }

    func markedTextChanged() {
        if hasMarkedText() != document.composing { document.composing.toggle() }
    }

    /// The keystroke's offsets are from before its mirror edits, which then move the selection as they move typing.
    func finish(_ stroke: Keystroke) {
        if let selection = stroke.selection { self.selection = selection.range }
        let mirrored = mirror()
        if let partner = stroke.partner { showPartner(of: document.map([.caret(partner)], through: mirrored)[0].location) }
        switch stroke.completions {
        case .keep: break
        case .offer: completions.offer()
        case .close: completions.close()
        }
    }

    func tab(_ step: Int) {
        let answer = document.tab(selections, step: step)
        if let field = answer.field { return selection = field.range }
        apply(answer.edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    func shiftLines(_ step: Int) {
        guard isEditable else { return }
        _ = document.endSnippet()
        tab(step)
    }

    func cancel() {
        if completions.offered != nil {
            completions.close()
        } else if document.endSnippet() {
        } else if mathPreview.isWanted, let maths = math(at: caret) {
            dismissedMath = maths.start
            mathPreview.close()
        } else {
            completions.complete(explicit: true)
        }
    }

    private(set) lazy var completions = CompletionList(for: self)

    override func complete(_ sender: Any?) { completions.complete(explicit: true) }

    override func cancelOperation(_ sender: Any?) { cancel() }

    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { return cancelOperation(nil) }
        guard completions.offered != nil else { return keyCommand(selector) }
        switch selector {
        case #selector(moveUp(_:)): completions.move(-1)
        case #selector(moveDown(_:)): completions.move(1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): completions.accept()
        default: keyCommand(selector)
        }
    }

    private func keyCommand(_ selector: Selector) {
        stepping = NSStringFromSelector(selector).hasPrefix("move")
        defer { stepping = false }
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        super.didChangeText()
        if !mirrorHeld { mirror() }
    }

    private var mirrorHeld = false

    private func holdingMirror(_ edit: () -> Void) {
        mirrorHeld = true
        edit()
        mirrorHeld = false
    }

    @discardableResult
    private func mirror() -> [TextEdit] {
        let edits = sync.mirror(composing: hasMarkedText())
        guard !edits.isEmpty else { return [] }
        let kept = document.map(selections, through: edits)
        sync.mirroring = true
        replace(edits)
        sync.mirroring = false
        setSelectedRanges(kept.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        breakUndoCoalescing()
        return edits
    }

    /// Makes edits given back to front in one TextKit pass: a pass per edit updates every paragraph after it and moves the
    /// selection, which parses for the maths preview, so 2,000 took 15 s. Each edit still asks to change, keeping its undo
    /// step, and the core takes them one by one.
    private func replace(_ edits: some Sequence<TextEdit>) {
        guard let storage = textStorage else { return }
        var changed = false
        storage.beginEditing()
        for edit in edits where shouldChangeText(in: edit.range, replacementString: edit.text) {
            storage.replaceCharacters(in: edit.range, with: edit.text)
            sync.batch(edit)
            changed = true
        }
        storage.endEditing()
        if changed { super.didChangeText() }
    }

    private func setsCursor(with event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let overGutter = inGutter(point, before: sourceTextStart)
        gutterHover(overGutter)
        if updateDividerCursor(with: event) { return true }
        let overControl = overGutter && (point.x < gutter.numbersEnd || foldLine(at: point) != nil)
        guard overControl || issue(at: event) != nil else { return false }
        NSCursor.arrow.set()
        return true
    }

    private func inGutter(_ point: NSPoint, before edge: CGFloat) -> Bool {
        visibleRect.contains(point) && point.x < edge
    }

    private func issue(at event: NSEvent) -> IssueOverlay.Row? { issues.message(at: convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) {
        guard !setsCursor(with: event) else { return hoverHelp.close() }
        super.mouseMoved(with: event)
        hoverHelp.moved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { if !setsCursor(with: event) { super.mouseEntered(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if !setsCursor(with: event) { super.cursorUpdate(with: event) } }

    override func mouseExited(with event: NSEvent) {
        gutterHover(false)
        hoverHelp.exited()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown {
            let point = convert(event.locationInWindow, from: nil)
            if foldClick(at: point) || inGutter(point, before: gutter.numbersEnd) { return }
        }
        let held = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.type == .leftMouseDown, held.isEmpty, let row = issue(at: event), let up = release(of: event) {
            if row.message?.rect.contains(convert(up.locationInWindow, from: nil)) == true { issues.clicked(row.line) }
            return
        }
        if event.type == .leftMouseDown, held == .command,
           let place = document.definition(at: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))?.places.first,
           release(of: event) != nil {
            return openDefinition(place)
        }
        if event.type == .leftMouseDown, held == .option, release(of: event) != nil {
            return quickHelp(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), false)
        }
        super.mouseDown(with: event)
        if isDoubleClick(event), !document.selectsCommand(selectedRange()) { forwardSync(true)?() }
    }

    private func release(of down: NSEvent) -> NSEvent? {
        guard down.clickCount == 1 else { return nil }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return next }
            if hypot(next.locationInWindow.x - down.locationInWindow.x, next.locationInWindow.y - down.locationInWindow.y) > 3 {
                window?.postEvent(next, atStart: true)
                return nil
            }
        }
        return nil
    }

    private func files(_ board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func dragOperation(_ info: any NSDraggingInfo, textViews own: () -> NSDragOperation) -> NSDragOperation {
        let files = files(info.draggingPasteboard)
        guard !files.isEmpty else { return own() }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return [] }
        if case .open = drop {} else {
            guard isEditable else { return [] }
            _ = own()
        }
        return info.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation { dragOperation(info) { super.draggingEntered(info) } }
    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation { dragOperation(info) { super.draggingUpdated(info) } }

    override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
        let files = files(info.draggingPasteboard)
        guard !files.isEmpty else { return super.performDragOperation(info) }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return false }
        if case .open(let open) = drop {
            open()
            return true
        }
        guard isEditable else { return false }
        setSelectedRange(.caret(characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))))
        window?.makeFirstResponder(self)
        Task.immediate { await insertFigure(drop) }
        return true
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let drop = pasted(NSPasteboard.general) else { return super.paste(sender) }
        Task.immediate { await insertFigure(drop) }
    }

    func pasted(_ board: NSPasteboard) -> FileDrop? {
        let figure = files(board).lazy.compactMap(fileDrop).first { if case .open = $0 { false } else { true } }
        return figure ?? pastedImage(board)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, NSPasteboard.general.availableType(from: [.png, .tiff]) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    private func pastedImage(_ board: NSPasteboard) -> FileDrop? {
        guard board.string(forType: .string) == nil,
              let png = board.data(forType: .png)
                ?? board.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        else { return nil }
        return figure(png, as: "png")
    }

    private func figure(_ data: Data, as type: String) -> FileDrop? {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: String(localized: "Pasted Graphic") + "." + type)
        let gone = { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: file)) != nil, case .copy(let copy) = fileDrop(file) else {
            gone()
            return nil
        }
        return .copy {
            defer { gone() }
            return await copy()
        }
    }

    private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    /// What Continuity Camera's items can come as; Services return only types the app registered at launch.
    static let imported: [NSPasteboard.PasteboardType] = [.pdf, jpeg, .png, .tiff]

    // Continuity Camera offers Take Photo, Scan Documents and Add Sketch to a requestor for images.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, isEditable, Self.imported.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// A scan's PDF and a photo's JPEG stay as they come, since LaTeX includes both.
    override func readSelection(from board: NSPasteboard) -> Bool {
        guard isEditable, board.string(forType: .string) == nil,
              let drop = board.data(forType: .pdf).flatMap({ figure($0, as: "pdf") })
                ?? board.data(forType: Self.jpeg).flatMap({ figure($0, as: "jpg") }) ?? pastedImage(board)
        else { return super.readSelection(from: board) }
        Task.immediate { await insertFigure(drop) }
        return true
    }

    func insertFigure(_ drop: FileDrop) async {
        let shown = document, at = selection, version = document.version
        let text: String? = switch drop {
        case .open: nil
        case .insert(let text): text
        case .copy(let copy): await copy()
        }
        guard let text else { return }
        guard document === shown, isEditable else { return NSSound.beep() }
        let target = document.version == version ? at : .caret(caret)
        apply([TextEdit(target, text)], named: String(localized: "Insert Figure"),
              selecting: [NSRange(location: target.location, length: (text as NSString).length)])
    }

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
