import AppKit
import SwiftUI
import TeXLocalSyntax

/// A project's source editor: one native text view (`SourceTextView`) for its
/// text files, each file's text, undo and selection kept while another shows;
/// the find bar's search; and the formatting commands, whose LaTeX is the core's.
final class SourceEditor: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = SourceTextView(usingTextLayoutManager: true)
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
    /// shown while nothing has the keyboard (as the project opens), it takes it.
    var shown = false {
        didSet {
            scrollView.isHidden = !shown
            if shown, !oldValue, let window = scrollView.window, window.firstResponder === window { focus() }
        }
    }

    override init() {
        super.init()
        let text = textView
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.isRichText = false
        text.importsGraphics = false
        text.usesFontPanel = false
        text.allowsUndo = true
        // A code editor's: nothing underlined, where every command would be
        // a misspelling, and nothing corrected: smart dashes and quotes
        // would rewrite the LaTeX (-- became an em dash).
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
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
        scrollView.hasVerticalScroller = true
        scrollView.documentView = text
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
        if focus { self.focus() }
    }

    /// The text and the file it belongs to.
    var document: (path: String, text: String)? {
        path.map { ($0, textView.string) }
    }

    /// Forget a file's kept state after it's renamed or deleted.
    func forget(path: String) {
        kept[path] = nil
    }

    /// Follows a rename: the file, or everything under a renamed folder, keeps
    /// its state (undo included) under the new path.
    func rename(from: String, to: String) {
        kept = Dictionary(uniqueKeysWithValues: kept.map { (remapPath($0.key, from: from, to: to), $0.value) })
        path = path.map { remapPath($0, from: from, to: to) }
    }

    var symbols: Symbols {
        get { textView.symbols }
        set { textView.symbols = newValue }
    }

    func focus() {
        guard shown else { return }
        textView.window?.makeFirstResponder(textView)
    }

    // ---------- where it is ----------

    var currentLine: Int {
        Int(textView.document.lineAt(offset: UInt32(textView.selectedRange().location)))
    }

    /// `atTop` puts the line at the top of the view, as an outline's jump to a
    /// heading does; otherwise it's centred, with the lines round it. The
    /// system's find indicator shows where it went.
    func reveal(line: Int, atTop: Bool = false, focus: Bool = true) {
        let document = textView.document
        let start = Int(document.lineStart(line: UInt32(max(1, line))))
        let end = line < Int(document.lineCount()) ? Int(document.lineStart(line: UInt32(line + 1))) - 1 : (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: 0))
        scroll(to: start, atTop: atTop)
        if focus { self.focus() }
        if end > start {
            // Once the scroll's layout is done.
            DispatchQueue.main.async { self.textView.showFindIndicator(for: NSRange(location: start, length: end - start)) }
        }
    }

    private func scroll(to offset: Int, atTop: Bool) {
        guard let manager = textView.textLayoutManager, let whole = textView.textRange(NSRange(location: 0, length: offset)) else { return }
        // Laid out down to the line, so its place is exact rather than estimated.
        manager.ensureLayout(for: whole)
        guard let fragment = manager.textLayoutFragment(for: whole.endLocation) else { return }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        let clip = scrollView.contentView, insets = scrollView.contentInsets
        let shown = clip.bounds.height - insets.top - insets.bottom
        let y = atTop ? frame.minY - insets.top : frame.midY - insets.top - shown / 2
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The first line at least half showing below the toolbar.
    @objc private func scrolled() {
        guard let manager = textView.textLayoutManager, let font = textView.font else { return }
        let y = scrollView.contentView.bounds.minY + scrollView.contentInsets.top - textView.textContainerOrigin.y
            + font.boundingRectForFont.height / 2
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return }
        let line = Int(textView.document.lineAt(offset: UInt32(textView.offset(fragment.rangeInElement.location))))
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
        let range = TextRange(start: UInt32(selection.location), length: UInt32(selection.length))
        let insert = { (insertion: Insertion, name: String) in
            self.textView.apply([insertion.edit], named: name, select: NSRange(location: Int(insertion.caret), length: 0))
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
            let selections = textView.selectedRanges.map(\.rangeValue).map {
                TextRange(start: UInt32($0.location), length: UInt32($0.length))
            }
            textView.apply(document.toggleComment(selections: selections), named: String(localized: "Comment"))
        case .heading:
            insert(document.setHeading(caret: range.start, command: argument ?? ""), String(localized: "Section Level"))
        case .symbol:
            insert(document.insertSymbol(command: argument ?? "", selection: range), String(localized: "Insert Symbol"))
        case .block:
            guard let block = document.insertBlock(id: argument ?? "", selection: range) else { return false }
            insert(block, String(localized: "Insert"))
        }
        focus()
        return true
    }

    /// Round the selection, which stays selected (or the caret, between them).
    private func wrap(_ prefix: String, _ suffix: String, named name: String) {
        let selection = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: selection)
        let edit = TextEdit(start: UInt32(selection.location), length: UInt32(selection.length), text: prefix + selected + suffix)
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
                TextEdit(start: UInt32(range.location), length: UInt32(range.length), text: query.replacement(for: range, in: text))
            }
            textView.apply(edits, named: String(localized: "Replace All"))
            return
        }
        let selection = textView.selectedRange()
        guard let hit = next(from: selection.location) else { return }
        guard hit == selection else { return select(hit) }
        let replacement = query.replacement(for: hit, in: text)
        let edit = TextEdit(start: UInt32(hit.location), length: UInt32(hit.length), text: replacement)
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
        return query.firstMatch(in: text, from: location) ?? query.firstMatch(in: text, from: 0)
    }

    private func previous(before location: Int) -> NSRange? {
        let text = textView.string as NSString
        return query.lastMatch(in: text, before: location) ?? query.lastMatch(in: text, before: text.length)
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
        textView.font = font
        textView.textColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        textView.palette = appearance.palette
        textView.updateGutterWidth()
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

/// The editor's formatting commands.
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
    static let palette = EditorPalette.standard
    static let font = EditorFont.system
    static let fontSize = Int(NSFont.systemFontSize)
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
        guard let escapes = try? NSRegularExpression(pattern: #"\\([nrt\\])"#) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for match in escapes.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += ["n": "\n", "r": "\r", "t": "\t", "\\": "\\"][ns.substring(with: match.range(at: 1))]!
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
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

    private func each(in text: NSString, range: NSRange, _ body: (NSRange, inout Bool) -> Void) {
        guard let expression else { return }
        expression.enumerateMatches(in: text as String, range: range) { result, _, stop in
            guard let r = result?.range, r.length > 0, isWhole(r, in: text) else { return }
            var halt = false
            body(r, &halt)
            if halt { stop.pointee = true }
        }
    }

    /// In order, at most `limit`, and whether there were more.
    func matches(in text: NSString, limit: Int) -> (ranges: [NSRange], limited: Bool) {
        var ranges: [NSRange] = [], limited = false
        each(in: text, range: NSRange(location: 0, length: text.length)) { r, stop in
            if ranges.count == limit {
                limited = true
                stop = true
            } else {
                ranges.append(r)
            }
        }
        return (ranges, limited)
    }

    func firstMatch(in text: NSString, from location: Int) -> NSRange? {
        var found: NSRange?
        each(in: text, range: NSRange(location: location, length: text.length - location)) { r, stop in
            found = r
            stop = true
        }
        return found
    }

    func lastMatch(in text: NSString, before location: Int) -> NSRange? {
        var found: NSRange?
        each(in: text, range: NSRange(location: 0, length: location)) { r, _ in found = r }
        return found
    }

    /// What replaces a match: in a regular expression, $& is the match,
    /// $1… its groups and $$ a dollar sign (JavaScript's).
    func replacement(for range: NSRange, in text: NSString) -> String {
        let replace = Self.unquote(self.replace)
        guard regexp, let expression,
              let match = expression.firstMatch(in: text as String, options: .anchored, range: range),
              let references = try? NSRegularExpression(pattern: #"\$([$&]|\d+)"#) else { return replace }
        let ns = replace as NSString
        var out = "", last = 0
        for reference in references.matches(in: replace, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: reference.range.location - last))
            last = NSMaxRange(reference.range)
            let name = ns.substring(with: reference.range(at: 1))
            if name == "&" {
                out += text.substring(with: match.range)
            } else if name == "$" {
                out += "$"
            } else if let group = (1...name.count).reversed().first(where: { n in
                Int(name.prefix(n)).map { $0 > 0 && $0 < match.numberOfRanges } ?? false
            }) {
                // The longest group number there is, the rest of the digits as they are.
                let captured = match.range(at: Int(name.prefix(group))!)
                out += (captured.location == NSNotFound ? "" : text.substring(with: captured)) + name.dropFirst(group)
            } else {
                out += ns.substring(with: reference.range)
            }
        }
        return out + ns.substring(from: last)
    }
}

/// A search's matches: `index` from 1 (0 when the selection isn't one);
/// `limited` when there are more than were counted.
struct FindMatches: Equatable {
    var index = 0
    var total = 0
    var limited = false

    /// "3 of 12", "12 matches", "1 of 5000+", "Not found", or nothing before a search.
    func label(for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total)\(limited ? "+" : "")"
        if index > 0 { return String(localized: "\(index) of \(count)") }
        if limited { return String(localized: "\(count) matches") }
        return String(AttributedString(localized: "^[\(total) match](inflect: true)").characters)
    }
}
