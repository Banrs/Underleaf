import PDFKit

extension PDFController {
    /// The word selected in the find bar's colour, unless the find bar is open with its own.
    func highlight(_ selection: PDFSelection?, or rect: CGRect, on page: PDFPage) {
        if let selection, !find.isOpen {
            view.removeMark()
            selection.color = .findHighlightColor
            view.setCurrentSelection(selection, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            view.flash(rect, on: page)
        }
    }
}
