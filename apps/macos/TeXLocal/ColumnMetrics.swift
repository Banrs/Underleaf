import CoreGraphics

enum ColumnMetrics {
    /// The sidebar opens at the width of AppKit's inspector (27.2), so the side columns frame the editors alike.
    static let sidebarIdeal: CGFloat = 270
    static let sidebarMinimum: CGFloat = 222
    static let detentReach: CGFloat = 8
    static let windowControls: CGFloat = 132
    /// The toolbar's sections are AppKit's layout of the default tools (27.2), measured, for Compile's word alone
    /// (`fitToolbar`): it has no API that tells them. The PDF and Inspector toggles, over the inspector or the last pane.
    static let toggles: CGFloat = 92
    /// The source's tools: Back, AppKit's narrowest title and Format, Math and Insert.
    static let sourceTools: CGFloat = 338
    /// The PDF's: Zoom, and Compile as its word.
    static let zoom: CGFloat = 156
    static let compile: CGFloat = 90
    /// What Compile's word takes over its symbol: 74 pt against 36.
    static let compileWord: CGFloat = 38
    /// The source|PDF separator's own gap, where no divider places it: before Compile while the PDF is hidden.
    static let separator: CGFloat = 5
    static let sourceMinimum: CGFloat = 260
    /// In a narrower window AppKit takes Compile and then Back to the overflow menu too (27.2).
    static let toolbarMinimum: CGFloat = 542
    /// What the narrowest window leaves beside the source's section of the toolbar, so the divider can stay under the
    /// toolbar's separator there (`joinDivider`).
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
    /// A window on its way there folds the sidebar and the inspector, as Mail's does.
    static let contentMinimum = CGSize(width: toolbarMinimum, height: 400)
}
