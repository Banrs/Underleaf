import CoreGraphics

enum ColumnMetrics {
    /// The source's and the PDF's least width, each a readable column.
    static let paneMinimum: CGFloat = 260
    static let pdfShare: CGFloat = 0.5
    static let panelMinimum: CGFloat = 140
    /// Narrower, AppKit takes Compile to the overflow menu (measured); the panes are wider than their least.
    static let toolbarMinimum: CGFloat = 533
    /// On its way there the window folds the sidebar and the inspector, as Mail's does, and AppKit's toolbar puts what has
    /// no room in its overflow menu.
    static let contentMinimum = CGSize(width: toolbarMinimum, height: 400)
}
