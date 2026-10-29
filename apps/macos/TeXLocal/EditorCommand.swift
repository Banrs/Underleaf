import Observation

enum EditorCommand: Equatable {
    case bold, italic, underline, math, displayMath, comment, moveLineUp, moveLineDown, duplicateLine, deleteLine
    case fold, unfold, foldAll, unfoldAll
    case heading(String)
    case symbol(String)
    case block(id: String, title: String? = nil)
    case inline(template: String, title: String? = nil)
}

@Observable final class EditorChanges { var count = 0 }
