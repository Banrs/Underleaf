import CoreGraphics

enum ColumnMetrics {
    /// The source's and the PDF's least width, each a readable column.
    static let paneMinimum: CGFloat = 260
    static let pdfShare: CGFloat = 0.5
    static let panelMinimum: CGFloat = 140
    /// Both panes at their least: on its way there the window folds the sidebar and the inspector, as Mail's does, and
    /// AppKit's toolbar puts what has no room in its overflow menu.
    static let contentMinimum = CGSize(width: 2 * paneMinimum + 1, height: 400)
}
