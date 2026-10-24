import SwiftUI

enum EditorCommand: Equatable {
    case bold, italic, underline, math, displayMath, comment, moveLineUp, moveLineDown, duplicateLine, deleteLine
    case fold, unfold, foldAll, unfoldAll
    /// Without its backslash; empty for Normal Text.
    case heading(String)
    case symbol(String)
    /// The core's block by its id; the title names the undo.
    case block(id: String, title: String? = nil)
    /// "$0" is where the selection goes.
    case inline(template: String, title: String? = nil)
}

enum EditorPrefs {
    static let fontSize = Int(NSFont.systemFontSize)
    static let fontSizes = 10...28

    static var spellCheck: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.editorSpellCheck) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.editorSpellCheck) }
    }
}

@Observable final class EditorChanges { var count = 0 }
