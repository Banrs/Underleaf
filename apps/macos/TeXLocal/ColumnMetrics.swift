import CoreGraphics

/// AppKit gives a sidebar and an inspector their standard widths, and the other panes none: without a minimum a pane can
/// be dragged to nothing. These keep each pane in use, and the source and the PDF their tools in the toolbar over them.
enum ColumnMetrics {
    static let sourceMinimum: CGFloat = 260
    static let pdfMinimum: CGFloat = 188
    static let columnsMinimum: CGFloat = 200
    static let panelMinimum: CGFloat = 140
    static let filesMinimum: CGFloat = 100
    static let outlineMinimum: CGFloat = 80
    /// The panel's and the outline's opening heights, as shares of the window's: the autosave keeps them afterwards.
    static let panelShare: CGFloat = 0.25
    static let outlineShare: CGFloat = 0.45
}
