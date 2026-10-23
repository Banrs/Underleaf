import UIKit

/// UIKit's spelling can't be kept to the prose, so the view checks what shows itself, as the Mac's checker does once told
/// what is TeX (`codeRanges`): misspelt words underlined as UIKit underlines them, their guesses first in the edit menu.
extension SourceTextView {
    /// After a pause, as the text or what shows changes.
    func checkSpellingSoon() {
        spelling.task?.cancel()
        spelling.task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { self?.checkSpelling() }
        }
    }

    private func checkSpelling() {
        spelling.misspelt = []
        defer { underlay.setNeedsDisplay() }
        guard checksSpelling, let first = fragments.first, let last = fragments.last, let language = Self.spellingLanguage else { return }
        let shown = NSRange(location: first.offset, length: offset(last.fragment.rangeInElement.endLocation) - first.offset)
        let code = document.codeRanges(in: shown, for: .spelling)
        let text = source as String
        var at = shown.location
        while at < NSMaxRange(shown) {
            let found = spelling.checker.rangeOfMisspelledWord(in: text, range: shown, startingAt: at, wrap: false, language: language)
            guard found.location != NSNotFound, found.length > 0 else { break }
            at = NSMaxRange(found)
            // Not the word being typed, as UIKit's own checker waits for it.
            let typing = isFirstResponder && selectedRange.length == 0 && NSLocationInRange(caret, NSRange(location: found.location, length: found.length + 1))
            if !typing, !code.contains(where: { NSIntersectionRange($0, found).length > 0 }) { spelling.misspelt.append(found) }
        }
    }

    /// The person's language where the checker has it.
    private static var spellingLanguage: String? {
        let available = UITextChecker.availableLanguages
        let preferred = Locale.preferredLanguages.lazy.map { $0.replacingOccurrences(of: "-", with: "_") }
        return preferred.compactMap { language in available.first { $0 == language || $0.hasPrefix(language.prefix(2)) } }.first
            ?? available.first
    }

    /// The misspelt word the selection is in, and its guesses.
    func misspelling() -> (range: NSRange, guesses: [String])? {
        guard let language = Self.spellingLanguage,
              let found = spelling.misspelt.first(where: { $0.location <= caret && NSMaxRange(selectedRange) <= NSMaxRange($0) })
        else { return nil }
        let guesses = spelling.checker.guesses(forWordRange: found, in: source as String, language: language) ?? []
        return (found, Array(guesses.prefix(3)))
    }

    func correctSpelling(_ range: NSRange, to word: String) {
        apply([TextEdit(range, word)], named: String(localized: "Correct Spelling"), selecting: [.caret(range.location + (word as NSString).length)])
    }

    func learnSpelling(_ range: NSRange) {
        UITextChecker.learnWord(source.substring(with: range))
        checkSpelling()
    }

    /// A dotted line under each word, in red, as UIKit's own.
    func drawMisspelt(in rect: CGRect) {
        UIColor.systemRed.setFill()
        for word in spelling.misspelt {
            guard let drawn = segments(word), drawn.intersects(rect) else { continue }
            var x = drawn.minX
            while x < drawn.maxX - 1 {
                UIBezierPath(ovalIn: CGRect(x: x, y: drawn.maxY - 2.5, width: 2, height: 2)).fill()
                x += 4
            }
        }
    }
}

/// The checker, what it last found and its next pass.
final class Spelling {
    let checker = UITextChecker()
    var misspelt: [NSRange] = []
    var task: Task<Void, Never>?
}
