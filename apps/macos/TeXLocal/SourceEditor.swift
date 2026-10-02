import AppKit
import SwiftUI

/// A word plus its occurrence in source/PDF text. Offsets are UTF-16, as AppKit/PDFKit use.
nonisolated struct SyncTeXWord: Equatable, Sendable {
    let text: String
    let offset: Int
    let context: String
    let contextOffset: Int
}

/// A project's source editor: one native text view (`SourceTextView`) for its
/// text files, each file's text, undo and selection kept while another shows;
/// the find bar's search; and the formatting commands, whose LaTeX is the core's.
final class SourceEditor: NSObject, NSTextViewDelegate {
    let scrollView = SourceTextView.scrollableTextView()
    let textView: SourceTextView
    var onChanged: () -> Void = {}
    var onCursor: (Int) -> Void = { _ in }
    /// The line at the top of the view.
    var onScroll: (Int) -> Void = { _ in }
    var onFindMatches: (FindMatches) -> Void = { _ in }

    /// The file shown.
    private(set) var path: String?
    /// The files shown before, as they were left: their state comes back
    /// only if their text is unchanged since.
    private var kept: [String: (text: String, undo: UndoManager, selection: NSRange)] = [:]
    private var undo = UndoManager()
    private var cursorLine = 1, topLine = 1

    /// Whether the column shows the editor rather than a preview or placeholder.
    /// Hidden, the text hands the keyboard on and leaves the key view loop;
    /// shown after a file opened with the keyboard asked for (as the project opens), it takes it.
    var shown = false {
        didSet {
            scrollView.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    private var focusWhenShown = false

    override init() {
        // AppKit's own plain-text scroll view: TextKit 2, sized to its text.
        textView = scrollView.documentView as! SourceTextView
        super.init()
        let text = textView
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.allowsUndo = true
        // Native spelling and correction in prose only (below). Smart dashes
        // and quotes would rewrite the LaTeX (-- to an em dash).
        text.isContinuousSpellCheckingEnabled = EditorPrefs.spellCheck
        text.isGrammarCheckingEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.inlinePredictionType = .no
        text.setAccessibilityLabel(String(localized: "Source"))
        text.delegate = self
        text.textStorage?.delegate = text
        // AppKit hides scrollers when the document fits and follows the system scroller style.
        scrollView.autohidesScrollers = true
        // The clip shows under the toolbar above the first line, where AppKit
        // takes the column's colour for its band and edge effect.
        scrollView.drawsBackground = true
        scrollView.isHidden = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // ---------- files ----------

    /// Shows a file at its top. `focus` false leaves the keyboard where it is
    /// (choosing a file in the sidebar).
    func open(path: String, text: String, focus: Bool = true) {
        if let current = self.path { kept[current] = (textView.string, undo, textView.selectedRange()) }
        let prior = kept[path].flatMap { $0.text == text ? $0 : nil }
        self.path = path
        undo = prior?.undo ?? UndoManager()
        textView.load(text)
        let selection = prior?.selection ?? NSRange(location: 0, length: 0)
        textView.setSelectedRange(NSMaxRange(selection) <= (text as NSString).length ? selection : NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshFind()
        reportCursor()
        focusWhenShown = focus
        if focus { self.focus() }
    }

    /// The text and the file it belongs to.
    var document: (path: String, text: String)? {
        path.map { ($0, textView.string) }
    }

    /// Forget a file's kept state after it's deleted, or every file's under a deleted folder.
    func forget(path: String) {
        kept = kept.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    /// Follows a rename: the file, or everything under a renamed folder, keeps
    /// its state (undo included) under the new path.
    func rename(from: String, to: String) {
        kept = Dictionary(uniqueKeysWithValues: kept.map { (remapPath($0.key, from: from, to: to), $0.value) })
        path = path.map { remapPath($0, from: from, to: to) }
    }

    func focus() {
        guard shown else { return }
        textView.window?.makeFirstResponder(textView)
    }

    // ---------- where it is ----------

    var currentLine: Int {
        textView.document.line(at: textView.selectedRange().location)
    }

    /// The word at the caret, as the system's word selection takes it.
    var currentWord: String? { currentSyncWord?.text }

    /// SyncTeX needs the occurrence within the source line, not just its spelling.
    var currentSyncWord: SyncTeXWord? {
        let source = textView.string as NSString
        let position = textView.selectedRange().location
        let caret = NSRange(location: position, length: 0)
        let range = textView.selectionRange(forProposedRange: caret, granularity: .selectByWord)
        let selected = source.substring(with: range)
        let word = selected.trimmingCharacters(in: .alphanumerics.inverted)
        guard !word.isEmpty else { return nil }
        let start = range.location + (selected as NSString).range(of: word).location
        let line = source.lineRange(for: caret)
        return SyncTeXWord(text: word, offset: min(max(position - start, 0), (word as NSString).length - 1),
                           context: source.substring(with: line), contextOffset: start - line.location)
    }

    var currentColumn: Int { textView.selectedRange().location - textView.document.lineStart(currentLine) }

    /// `atTop` puts the line at the top of the view, as an outline's jump to a
    /// heading does; otherwise it's centred, with the lines round it. A `column`
    /// selects the word there. The system's find indicator shows where it went.
    func reveal(line: Int, column: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let document = textView.document
        let start = document.lineStart(line)
        let end = line < document.lineCount ? document.lineStart(line + 1) - 1 : (textView.string as NSString).length
        let word = column.map {
            textView.selectionRange(forProposedRange: NSRange(location: min(start + $0, end), length: 0), granularity: .selectByWord)
        }
        textView.setSelectedRange(word ?? NSRange(location: start, length: 0))
        scroll(to: start, atTop: atTop)
        if focus { self.focus() }
        let shown = word ?? NSRange(location: start, length: end - start)
        if shown.length > 0 {
            // Once the scroll's layout is done.
            DispatchQueue.main.async { self.textView.showFindIndicator(for: shown) }
        }
    }

    private func scroll(to offset: Int, atTop: Bool) {
        guard let target = textView.textRange(NSRange(location: offset, length: 0)) else { return }
        let insets = scrollView.contentInsets, shown = scrollView.contentView.bounds.height - insets.top - insets.bottom
        textView.scroll(target.location) { atTop ? $0.minY - insets.top : $0.midY - insets.top - shown / 2 }
    }

    /// The first line at least half showing below the toolbar.
    @objc private func scrolled() {
        textView.previewMath()
        guard let manager = textView.textLayoutManager, let font = textView.font else { return }
        let y = scrollView.contentView.bounds.minY + scrollView.contentInsets.top - textView.textContainerOrigin.y
            + font.boundingRectForFont.height / 2
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return }
        let line = textView.document.line(at: textView.offset(fragment.rangeInElement.location))
        guard line != topLine else { return }
        topLine = line
        onScroll(line)
    }

    private func reportCursor() {
        let line = currentLine
        guard line != cursorLine else { return }
        cursorLine = line
        onCursor(line)
    }

    func textDidChange(_ notification: Notification) {
        refreshFind()
        onChanged()
    }

    /// Spelling and correction apply to prose, including comments and math's
    /// text arguments; commands, math, literal code and TeX names are protected.
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let document = textView.document
        // The highlighter also colours words inside \text{…} as math. The
        // prose scan owns those boundaries; colours supply syntax names only.
        let code = document.highlights(in: range).filter {
            [.command, .argument, .stringLiteral, .builtin].contains($0.kind)
        }.map(\.range) + document.notProse(in: range)
        return results.filter { result in
            // Language metadata can span both prose and TeX without changing it.
            if result.resultType == .orthography { return true }
            // Native results count from the checked range's start. Rebase only
            // the comparison and return the original results for AppKit to apply.
            let found = NSRange(location: range.location + result.range.location, length: result.range.length)
            return !code.contains { NSIntersectionRange($0, found).length > 0 }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        reportCursor()
        if findShown { markFindMatches() }
    }

    // ---------- commands ----------

    /// False when there's no text to run it on, or no block of that id.
    @discardableResult
    func perform(_ command: EditorCommand, _ argument: String? = nil) -> Bool {
        guard path != nil else { return false }
        let document = textView.document, selection = textView.selectedRange()
        let insert = { (insertion: Insertion?, name: String) in
            guard let insertion else { return false }
            self.textView.apply([insertion.edit], named: name, select: NSRange(location: insertion.caret, length: 0))
            self.textView.startSnippet(insertion.fields, at: insertion.edit.start)
            return true
        }
        switch command {
        case .bold: wrap("\\textbf{", "}", named: String(localized: "Bold"))
        case .italic: wrap("\\textit{", "}", named: String(localized: "Italic"))
        case .math: wrap("$", "$", named: String(localized: "Inline Math"))
        case .displayMath: wrap("\\[", "\\]", named: String(localized: "Display Math"))
        case .inline:
            // A template such as \ref{$0}: "$0" is where the selection goes.
            let parts = ((argument ?? "") + "$0").components(separatedBy: "$0")
            wrap(parts[0], parts[1...].dropLast().joined(separator: "$0"), named: String(localized: "Insert"))
            // Empty braces: the labels or citations for them, once the menu has closed.
            if selection.length == 0 { DispatchQueue.main.async { self.textView.complete(nil) } }
        case .comment:
            textView.apply(document.toggleComment(textView.selectedRanges.map(\.rangeValue)), named: String(localized: "Comment"))
        case .heading:
            guard insert(document.setHeading(caret: selection.location, command: argument ?? ""), String(localized: "Section Level")) else { return false }
        case .symbol:
            guard insert(document.insertSymbol(argument ?? "", replacing: selection), String(localized: "Insert Symbol")) else { return false }
        case .block:
            guard insert(document.insertBlock(argument ?? "", replacing: selection), String(localized: "Insert")) else { return false }
        }
        focus()
        return true
    }

    /// Round the selection, which stays selected (or the caret, between them).
    private func wrap(_ prefix: String, _ suffix: String, named name: String) {
        let selection = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: selection)
        let edit = TextEdit(selection, prefix + selected + suffix)
        textView.apply([edit], named: name,
                       select: NSRange(location: selection.location + (prefix as NSString).length, length: selection.length))
    }

    // ---------- find ----------

    private var query = FindQuery()
    private(set) var findShown = false
    private var matches: (ranges: [NSRange], limited: Bool) = ([], false)

    /// The selection as a query: short and on one line, a line break as \n
    /// (CodeMirror's `defaultQuery`); nil otherwise.
    var selectionQuery: String? {
        let selection = textView.selectedRange()
        guard selection.length > 0, selection.length <= 100 else { return nil }
        return (textView.string as NSString).substring(with: selection).replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The find bar's query. A changed search selects its first match from
    /// the selection on, as you type, as a Mac find bar does.
    func setFind(_ query: FindQuery) {
        let changed = query.search != self.query.search || !findShown
        self.query = query
        findShown = true
        refreshFind()
        guard changed, let hit = next(from: textView.selectedRange().location) else { return }
        select(hit, centred: true)
    }

    func closeFind() {
        findShown = false
        refreshFind()
    }

    /// The next or previous match, round the end; false with nothing to find.
    @discardableResult
    func findStep(_ delta: Int) -> Bool {
        guard query.isValid else { return false }
        let selection = textView.selectedRange()
        guard let hit = delta > 0 ? next(from: NSMaxRange(selection)) : previous(before: selection.location) else { return true }
        select(hit)
        return true
    }

    /// Replace: the selection, if it's a match, and on to the next one; else
    /// to the next one. Replace All: every match, as one undo step.
    func replace(all: Bool) {
        let text = textView.string as NSString
        if all {
            let edits = query.matches(in: text, limit: .max).ranges.map { range in
                TextEdit(range, query.replacement(for: range, in: text))
            }
            textView.apply(edits, named: String(localized: "Replace All"))
            return
        }
        let selection = textView.selectedRange()
        guard let hit = next(from: selection.location) else { return }
        guard hit == selection else { return select(hit) }
        let replacement = query.replacement(for: hit, in: text)
        let edit = TextEdit(hit, replacement)
        textView.apply([edit], named: String(localized: "Replace"), select: NSRange(location: hit.location + (replacement as NSString).length, length: 0))
        if let after = next(from: textView.selectedRange().location) { select(after) }
    }

    /// A match selected and shown by the system's find indicator, as
    /// TextEdit's find bar shows it.
    private func select(_ match: NSRange, centred: Bool = false) {
        textView.setSelectedRange(match)
        if centred { scroll(to: match.location, atTop: false) } else { textView.scrollRangeToVisible(match) }
        textView.showFindIndicator(for: match)
    }

    private func next(from location: Int) -> NSRange? {
        let text = textView.string as NSString
        let after = NSRange(location: location, length: text.length - location)
        return query.matches(in: text, range: after, limit: 1).ranges.first ?? query.matches(in: text, limit: 1).ranges.first
    }

    private func previous(before location: Int) -> NSRange? {
        let text = textView.string as NSString
        let before = query.matches(in: text, range: NSRange(location: 0, length: location), limit: .max).ranges
        return before.last ?? query.matches(in: text, limit: .max).ranges.last
    }

    /// The matches again, after the text or query changed.
    private func refreshFind() {
        matches = findShown ? query.matches(in: textView.string as NSString, limit: 1000) : ([], false)
        markFindMatches()
    }

    private func markFindMatches() {
        let selection = textView.selectedRange()
        let index = matches.ranges.firstIndex(of: selection)
        textView.findMatches = matches.ranges
        guard findShown else { return }
        onFindMatches(FindMatches(index: index.map { $0 + 1 } ?? 0, total: matches.ranges.count, limited: matches.limited))
    }

    // ---------- appearance ----------

    /// Settings' palette, font and size.
    func setAppearance(_ appearance: EditorAppearance) {
        let font = appearance.font.font(ofSize: CGFloat(appearance.size)), color = appearance.palette.textColor
        let lines = Self.lineStyle(for: font)
        textView.font = font
        textView.textColor = color
        textView.defaultParagraphStyle = lines
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: lines]
        if let storage = textView.textStorage {
            storage.addAttribute(.paragraphStyle, value: lines, range: NSRange(location: 0, length: storage.length))
        }
        textView.palette = appearance.palette
        textView.updateGutterWidth()
    }

    /// The web's line height, 1.45 × the size, with the text in the middle
    /// of it as CSS puts it. TextKit puts a taller line's extra room above
    /// the text, so the line takes half of it and line spacing, below, the rest.
    private static func lineStyle(for font: NSFont) -> NSParagraphStyle {
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        let extra = max(0, font.pointSize * 1.45 - natural)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = natural + extra / 2
        style.maximumLineHeight = natural + extra / 2
        style.lineSpacing = extra / 2
        return style
    }
}

/// The project's source view: the editor's scroll view, which SwiftUI may
/// host again as it rebuilds this wrapper. It runs on under the toolbar and the
/// find bar, where AppKit draws its edge effect over the text.
struct EditorView: NSViewRepresentable {
    let editor: SourceEditor
    let shown: Bool

    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        if editor.shown != shown { editor.shown = shown }
    }
}

enum EditorCommand {
    case bold, italic, math, displayMath, comment, heading, symbol
    /// A block from the core's catalog (crates/texlocal-syntax), by id.
    case block
    /// A template with "$0" where the selection goes.
    case inline
}

struct EditorAppearance: Equatable {
    var palette: EditorPalette
    var font: EditorFont
    var size: Int
}

/// The syntax colours (`EditorPalette.color`).
enum EditorPalette: String, CaseIterable, Identifiable {
    /// The editor's own colours, One Dark in dark mode and CodeMirror's in
    /// light, so it isn't named for either.
    case standard = "onedark"
    case xcode

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Default"
        case .xcode: "Xcode"
        }
    }

    /// A kind's colour: the web editor's, CodeMirror's own in light and One
    /// Dark in dark for the default, Xcode's for Xcode, its dark comments
    /// lighter (web/src/editor.js). Nil leaves the text's colour.
    func color(_ kind: HighlightKind) -> NSColor? {
        if self == .xcode, kind == .invalid { return .systemRed }
        let (light, dark): (UInt32?, UInt32?) = switch (self, kind) {
        case (.standard, .command): (0x008855, 0xe5c07b)
        case (.standard, .argument): (0x221199, 0xd19a66)
        case (.standard, .mathDelimiter): (0x770088, 0xc678dd)
        case (.standard, .mathIdentifier): (0x225566, 0xd19a66)
        case (.standard, .number): (0x116644, 0xe5c07b)
        case (.standard, .comment): (0x994400, 0x7d8799)
        case (.standard, .invalid): (0xff0000, 0xffffff)
        case (.standard, .stringLiteral): (0xaa1111, 0x98c379)
        case (.standard, .builtin): (nil, 0xd19a66)
        case (.xcode, .command): (0x9b2393, 0xfc5fa3)
        case (.xcode, .argument): (0x1c464a, 0x9ef1dd)
        case (.xcode, .mathDelimiter): (0x643820, 0xfd8f3f)
        case (.xcode, .mathIdentifier), (.xcode, .builtin): (0x326d74, 0x67b7a4)
        case (.xcode, .number): (0x1c00cf, 0xd0bf69)
        case (.xcode, .comment): (0x5d6c79, 0x8a97a5)
        case (.xcode, .stringLiteral): (0xc41a16, 0xfc6a5d)
        case (.xcode, .invalid): (nil, nil)
        }
        guard light != nil || dark != nil else { return nil }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).map(NSColor.init(hex:)) ?? .textColor
        }
    }

    /// The text's own colour: One Dark's in dark for the default, the system's otherwise.
    var textColor: NSColor {
        guard self == .standard else { return .textColor }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0xabb2bf) : .textColor
        }
    }
}

enum EditorFont: String, CaseIterable, Identifiable {
    case system, jetbrains

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System Monospaced"
        case .jetbrains: "JetBrains Mono"
        }
    }

    func font(ofSize size: CGFloat) -> NSFont {
        switch self {
        case .system: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .jetbrains:
            Self.registerJetBrains
            return NSFont(name: "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// JetBrains Mono is the app's own (Resources/Fonts, the web's WOFF2),
    /// registered for the app the first time it's asked for: the Info.plist's
    /// ATSApplicationFontsPath doesn't take a WOFF2, which CoreText reads.
    private static let registerJetBrains: Void = {
        guard let url = Bundle.main.url(forResource: "jetbrains-mono-latin-400-normal", withExtension: "woff2",
                                        subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}

/// The keys and defaults Settings and the editor share.
enum EditorPrefs {
    static let paletteKey = "editorPalette", fontKey = "editorFont", fontSizeKey = "editorFontSize"
    static let spellCheckKey = "editorSpellCheck"
    static let palette = EditorPalette.standard
    static let font = EditorFont.system
    static let fontSize = Int(NSFont.systemFontSize)

    /// Edit › Spelling and Grammar › Check Spelling While Typing, as last set; on at first.
    static var spellCheck: Bool {
        get { UserDefaults.standard.object(forKey: spellCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: spellCheckKey) }
    }
}

/// The source's search, as CodeMirror's `SearchQuery` reads it: outside a
/// regular expression, \n, \r, \t and \\ stand for themselves in both fields.
nonisolated struct FindQuery: Equatable {
    var search = ""
    var replace = ""
    var caseSensitive = false
    var regexp = false
    var wholeWord = false

    var isValid: Bool { expression != nil }

    private static func unquote(_ text: String) -> String {
        text.replacing(/\\([nrt\\])/) { ["n": "\n", "r": "\r", "t": "\t"][$0.1] ?? "\\" }
    }

    private var expression: NSRegularExpression? {
        guard !search.isEmpty else { return nil }
        let pattern = regexp ? search : NSRegularExpression.escapedPattern(for: Self.unquote(search))
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
    }

    /// CodeMirror's whole-word test: at each end, one side or the other isn't a word character.
    private func isWhole(_ range: NSRange, in text: NSString) -> Bool {
        guard wholeWord else { return true }
        let word = { (i: Int) -> Bool in
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        let start = range.location, end = NSMaxRange(range)
        return (!word(start - 1) || !word(start)) && (!word(end) || !word(end - 1))
    }

    /// In order within `range` (the whole text by default), at most `limit`,
    /// and whether there were more.
    func matches(in text: NSString, range: NSRange? = nil, limit: Int) -> (ranges: [NSRange], limited: Bool) {
        var ranges: [NSRange] = [], limited = false
        expression?.enumerateMatches(in: text as String, range: range ?? NSRange(location: 0, length: text.length)) { result, _, stop in
            guard let r = result?.range, r.length > 0, isWhole(r, in: text) else { return }
            limited = ranges.count == limit
            if limited { stop.pointee = true } else { ranges.append(r) }
        }
        return (ranges, limited)
    }

    /// What replaces a match: in a regular expression, $& is the match,
    /// $1… its groups and $$ a dollar sign (JavaScript's).
    func replacement(for range: NSRange, in text: NSString) -> String {
        let replace = Self.unquote(self.replace)
        guard regexp, let match = expression?.firstMatch(in: text as String, options: .anchored, range: range) else { return replace }
        return replace.replacing(/\$([$&]|\d+)/) { reference in
            let name = reference.1
            if name == "&" { return text.substring(with: match.range) }
            if name == "$" { return "$" }
            // The longest group number there is, the rest of the digits as they are.
            guard let digits = (1...name.count).reversed().first(where: { n in
                Int(name.prefix(n)).map { $0 > 0 && $0 < match.numberOfRanges } ?? false
            }) else { return String(reference.0) }
            let captured = match.range(at: Int(name.prefix(digits))!)
            return (captured.location == NSNotFound ? "" : text.substring(with: captured)) + name.dropFirst(digits)
        }
    }
}

/// A search's matches: `index` from 1 (0 when the selection isn't one);
/// `limited` when there are more than were counted.
struct FindMatches: Equatable {
    var index = 0
    var total = 0
    var limited = false

    /// "3 of 12", "12 matches", "1 of 5,000+", "Not found", or nothing before a search.
    func label(for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total.formatted())\(limited ? "+" : "")"
        if index > 0 { return String(localized: "\(index) of \(count)") }
        if limited { return String(localized: "\(count) matches") }
        return String(AttributedString(localized: "^[\(total) match](inflect: true)").characters)
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
