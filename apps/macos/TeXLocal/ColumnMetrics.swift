import CoreGraphics

enum ColumnMetrics {
    /// The source's and the PDF's least width, each a readable column.
    static let paneMinimum: CGFloat = 260
    static let pdfShare: CGFloat = 0.5
    static let panelMinimum: CGFloat = 140
    /// AppKit's layout of the default tools, measured, for Compile's word alone: AppKit neither narrows a tool's view nor
    /// says what its overflow menu would take. The window controls and sidebar toggle; the PDF and Inspector toggles; the
    /// source's tools (Back, the narrowest title, Aa, Math and Insert); Zoom; Compile as its word; the source|PDF
    /// separator's own gap while the PDF is hidden.
    static let windowControls: CGFloat = 132
    static let toggles: CGFloat = 92
    static let sourceTools: CGFloat = 338
    static let zoom: CGFloat = 156
    static let compile: CGFloat = 90
    static let separator: CGFloat = 5
    /// Narrower, AppKit takes Compile's symbol to the overflow menu too (measured); the panes are wider than their least.
    static let toolbarMinimum: CGFloat = 533
    /// On its way there the window folds the sidebar and the inspector, as Mail's does, and AppKit's toolbar puts what has
    /// no room in its overflow menu.
    static let contentMinimum = CGSize(width: toolbarMinimum, height: 400)
}
