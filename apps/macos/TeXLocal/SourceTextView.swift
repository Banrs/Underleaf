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
        view.displayOptionsWatch = NSWorkspace.shared.notificationCenter.addObserver(
            of: NSWorkspace.self, for: .accessibilityDisplayOptionsDidChange) { [weak view] _ in view?.needsDisplay = true }
        return view
    }

    private var displayOptionsWatch: NotificationCenter.ObservationToken?

    var document = SourceDocument(text: "")
    var source: NSString { textStorage?.mutableString ?? "" }
    var undo = UndoManager()
    var fileDrop: (URL) -> FileDrop? = { _ in nil }
    enum FileDrop { case open(() -> Void), insert(String), copy(() async -> String?) }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }
    var openDefinition: (FilePlace) -> Void = { _ in }
    var quickHelp: (Int) -> Void = { _ in }
    private(set) var loading = false

    func show(_ text: String) {
        loading = true
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        issues.place()
        inputContext?.discardMarkedText()
        unmarkText()
        folded = []
        foldCache = nil
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        lastMath = nil
        dismissedMath = nil
        _ = document.endSnippet()
        endFieldTyping()
        completions.close()
        mark(nil)
        updateGutterWidth()
        staleColours = 0
    }

    private var changing: NSRange?

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard document.editable, super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else {
            return false
        }
        changing = affectedRanges.count == 1 && replacementStrings != nil ? affectedRanges[0].rangeValue : nil
        return true
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        let old = NSRange(location: edited.location, length: edited.length - delta)
        mirrorEdits = document.edit(old, with: textStorage.mutableString.substring(with: edited), changing: changing, mirroring: mirroring)
        foldsEdited(old, delta: delta)
        lastMath = nil
        staleColours = min(staleColours ?? edited.location, edited.location)
        changing = nil
        if gutter.digits != EditorGutter.digits(document.lineCount) { Task { self.updateGutterWidth() } }
    }

    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: [NSRange]? = nil) -> Bool {
        guard !edits.isEmpty else { return false }
        endFieldTyping()
        let selections = selecting ?? document.map(selectedRanges.map(\.rangeValue), through: edits)
        undoManager?.beginUndoGrouping()
        for edit in edits.reversed() where shouldChangeText(in: edit.range, replacementString: edit.text) {
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            didChangeText()
        }
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        if !selections.isEmpty { setSelectedRanges(selections.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false) }
        scrollRangeToVisible(selectedRange())
        return true
    }

    var fontSize = NSFont.systemFontSize { didSet { applyFont() } }
    var fontName = "" { didSet { if fontName != oldValue { applyFont() } } }
    private(set) var rowShift: CGFloat = 0
    private var applied: NSFont?

    private func applyFont() {
        let font = Self.font(named: fontName, size: fontSize, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
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
        let natural = font.ascender.rounded(.up) - font.descender.rounded(.down) + font.leading
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = (natural * 1.1).rounded()
        rowShift = (style.minimumLineHeight - natural) / 2
        defaultParagraphStyle = style
        textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: length))
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
        gutter.font = EditorGutter.font(forText: fontSize)
        issues.fontChanged(size: fontSize, text: font)
        updateGutterWidth()
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
    var syntaxTheme = SyntaxTheme.system {
        didSet { if syntaxTheme != oldValue { fragmentColours.removeAllObjects(); colour(from: 0) } }
    }
    var staleColours: Int?
    let fragmentColours = NSMapTable<NSTextLayoutFragment, NSArray>.weakToStrongObjects()
    var partnerMark: NSRange?
    var partnerDrawn: NSRect?
    var folded: [NSRange] = []
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
        if let over = selectionMoved(from: old) {
            super.setSelectedRanges([NSValue(range: over)], affinity: affinity, stillSelecting: stillSelecting)
        }
        if !typing {
            completions.close()
            endFieldTyping()
        }
        if partnerMark != nil { mark(nil) }
        previewMath()
        document.select(selectedRange(), mirroring: mirroring)
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
        guard let window else { return }
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

    func showQuickHelp(_ help: QuickHelp, at offset: Int) {
        guard let rect = popoverRect(at: offset) else { return }
        let bold = NSFontManager.shared.convert(font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular), toHaveTrait: .boldFontMask)
        let content = NSHostingController(rootView: QuickHelpView(help: help, font: bold) { [weak self] place in
            self?.helpPopover.close()
            self?.openDefinition(place)
        })
        content.sizingOptions = .preferredContentSize
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
    var composing: (Bool) -> Void = { _ in }
    var spellCheckToggled: (Bool) -> Void = { _ in }
    private var toldComposing = false
    private var typing = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextChanged()
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
        if let edit = stroke.edit {
            super.insertText(edit.text, replacementRange: edit.range)
        } else if stroke.selection == nil {
            super.insertText(string, replacementRange: replacementRange)
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
        super.insertText(edit.text, replacementRange: edit.range)
        finish(stroke)
    }

    override func insertTab(_ sender: Any?) { isEditable ? tab(1) : super.insertTab(sender) }
    override func insertBacktab(_ sender: Any?) { isEditable ? tab(-1) : super.insertBacktab(sender) }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        spellCheckToggled(isContinuousSpellCheckingEnabled)
    }

    func markedTextChanged() {
        guard hasMarkedText() != toldComposing else { return }
        toldComposing.toggle()
        composing(toldComposing)
    }

    func finish(_ stroke: Keystroke) {
        if let selection = stroke.selection { self.selection = selection.range }
        if let partner = stroke.partner { showPartner(of: partner) }
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

    override func cancelOperation(_ sender: Any?) {
        endFieldTyping()
        cancel()
    }

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

    private var mirroring = false
    private var mirrorEdits: [TextEdit] = []
    private var fieldTyping: (undo: UndoManager, watch: any NSObjectProtocol)?

    override func didChangeText() {
        super.didChangeText()
        guard !mirroring else { return }
        guard !mirrorEdits.isEmpty else { return endFieldTyping() }
        if fieldTyping == nil, let undo = undoManager, undo.groupsByEvent, !undo.isUndoing, !undo.isRedoing {
            undo.groupsByEvent = false
            let watch = NotificationCenter.default.addObserver(forName: .NSUndoManagerWillUndoChange, object: undo, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.endFieldTyping() }
            }
            fieldTyping = (undo, watch)
        }
        let edits = mirrorEdits, selection = selectedRange()
        mirrorEdits = []
        mirroring = true
        for edit in edits where shouldChangeText(in: edit.range, replacementString: edit.text) {
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            super.didChangeText()
        }
        mirroring = false
        setSelectedRange(selection)
    }

    private func endFieldTyping() {
        guard let (undo, watch) = fieldTyping else { return }
        fieldTyping = nil
        NotificationCenter.default.removeObserver(watch)
        if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = true
        breakUndoCoalescing()
    }

    private func setsCursor(with event: NSEvent) -> Bool {
        gutterHover(inGutter(event))
        if updateDividerCursor(with: event) { return true }
        guard inGutter(event) || issue(at: event) != nil || completions.contains(event.locationInWindow) else { return false }
        NSCursor.arrow.set()
        return true
    }

    private func inGutter(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return visibleRect.contains(point) && point.x < textContainerOrigin.x
    }

    private func issue(at event: NSEvent) -> IssueOverlay.Row? { issues.message(at: convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) { if !setsCursor(with: event) { super.mouseMoved(with: event) } }
    override func mouseEntered(with event: NSEvent) { if !setsCursor(with: event) { super.mouseEntered(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if !setsCursor(with: event) { super.cursorUpdate(with: event) } }

    override func mouseExited(with event: NSEvent) {
        gutterHover(false)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown, foldClick(at: convert(event.locationInWindow, from: nil)) { return }
        if event.type == .leftMouseDown, inGutter(event) { return selectLines(with: event) }
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
            return quickHelp(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
        }
        super.mouseDown(with: event)
        if isDoubleClick(event), !selectsCommandName { forwardSync(true)?() }
    }

    private var selectsCommandName: Bool {
        let selection = selectedRange(), text = string as NSString
        return selection.location > 0 && text.character(at: selection.location - 1) == 0x5C
            || selection.length > 0 && text.character(at: selection.location) == 0x5C
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

    private func selectLines(with event: NSEvent) {
        func line(at event: NSEvent) -> NSRange {
            let point = NSPoint(x: textContainerOrigin.x, y: convert(event.locationInWindow, from: nil).y)
            return source.lineRange(for: .caret(characterIndexForInsertion(at: point)))
        }
        let first = line(at: event)
        let anchor = event.modifierFlags.contains(.shift) ? selectedRange() : first
        window?.makeFirstResponder(self)
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var current = event
        repeat {
            setSelectedRange(NSUnionRange(anchor, line(at: current)))
            autoscroll(with: current)
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) else { break }
            if next.type != .periodic { current = next }
        } while current.type != .leftMouseUp
        let number = document.line(at: first.location)
        if selectedRange() == first, issues.issue(on: number) != nil { issues.clicked(number) }
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
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: String(localized: "Pasted Graphic") + ".png")
        let gone = { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? png.write(to: file)) != nil, case .copy(let copy) = fileDrop(file) else {
            gone()
            return nil
        }
        return .copy {
            defer { gone() }
            return await copy()
        }
    }

    func insertFigure(_ drop: FileDrop) async {
        let shown = document, at = selection, version = document.version
        let text: String? = switch drop {
        case .open: nil
        case .insert(let text): text
        case .copy(let copy): await copy()
        }
        guard let text, document === shown, isEditable else { return }
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
