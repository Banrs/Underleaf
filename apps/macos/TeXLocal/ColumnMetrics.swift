import CoreGraphics

enum ColumnMetrics {
    /// The width AppKit's inspector opens at (27.2), so the side columns frame the editors alike.
    static let sidebarIdeal: CGFloat = 270
    static let sidebarMinimum: CGFloat = 222
    static let detentReach: CGFloat = 8
    static let windowControls: CGFloat = 132
    /// AppKit's layout of the default tools, measured (27.2), for Compile's word alone: no API tells it. The PDF and
    /// Inspector toggles; the source's tools (Back, the narrowest title, Aa, Math and Insert); Zoom; Compile as its word,
    /// and what the word takes over the symbol; the source|PDF separator's own gap while the PDF is hidden.
    static let toggles: CGFloat = 92
    static let sourceTools: CGFloat = 338
    static let zoom: CGFloat = 156
    static let compile: CGFloat = 90
    static let compileWord: CGFloat = 38
    static let separator: CGFloat = 5
    static let sourceMinimum: CGFloat = 260
    /// Narrower, AppKit takes Compile and then Back to the overflow menu too (27.2).
    static let toolbarMinimum: CGFloat = 542
    /// What the narrowest window leaves beside the source's tools, so the divider can stay under the toolbar's separator.
    static let pdfMinimum: CGFloat = 188
    /// With the sidebar open the PDF's tools need more than its minimum (27.2).
    static let pdfRoom: CGFloat = 200
    static let pdfShare: CGFloat = 0.5
    static let columnsMinimum: CGFloat = 200
    static let panelMinimum: CGFloat = 140
    static let panelShare: CGFloat = 0.25
    static let filesMinimum: CGFloat = 100
    static let outlineMinimum: CGFloat = 80
    static let outlineShare: CGFloat = 0.45
    static let toolbarInset: CGFloat = 0.5
    /// On its way there the window folds the sidebar and the inspector, as Mail's does.
    static let contentMinimum = CGSize(width: toolbarMinimum, height: 400)
}
