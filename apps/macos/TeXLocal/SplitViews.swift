import AppKit
import PDFKit

extension NSView {
    /// TextKit and PDFKit still receive tracking events just inside the panes and replace the divider cursor,
    /// so only the actual divider hit target may choose the resize cursor.
    @discardableResult
    func updateDividerCursor(with event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, let workspace = window.contentView, let content = workspace.superview,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        // Toolbar cursor tracking owns views outside the workspace content.
        guard hit.isDescendant(of: workspace) else { return true }
        if let split = hit as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2,
           split.arrangedSubviews.allSatisfy({ !split.isSubviewCollapsed($0) }), isDescendant(of: split) {
            let position = split.arrangedSubviews[0].frame.maxX
            var directions: NSHorizontalDirection.Set = []
            if position > split.minPossiblePositionOfDivider(at: 0) { directions.insert(.left) }
            if position < split.maxPossiblePositionOfDivider(at: 0) { directions.insert(.right) }
            guard !directions.isEmpty else { return false }
            NSCursor.columnResize(directions: directions).set()
            return true
        }
        // NSTextView also receives mouse moves over its overlay scroller and, while first responder, over the PDF.
        if hit is NSScroller { NSCursor.arrow.set(); return true }
        if let pdf = sequence(first: hit, next: \.superview).first(where: { $0 is PDFView }) as? PDFView,
           self is NSTextView || NSCursor.isResizingColumn {
            pdf.setCursorFor(pdf.areaOfInterest(forMouse: event))
            return true
        }
        // Crossing the overlap need not enter a new pane tracking area: return a lingering resize cursor to the real hit view.
        if NSCursor.isResizingColumn {
            if hit is NSTextView || hit is NSTextField { NSCursor.iBeam.set() }
            else { NSCursor.arrow.set() }
        }
        return false
    }
}

extension NSCursor {
    static var isResizingColumn: Bool {
        current == .columnResize || current == .columnResize(directions: .left) || current == .columnResize(directions: .right)
    }
}

/// A split with thin dividers that says when it has loaded: the autosave restores which panes were collapsed as it loads,
/// and `loaded` puts back what the models say.
class SplitViewController: NSSplitViewController {
    var loaded: () -> Void = {}

    init(splitView: NSSplitView = NSSplitView(), isVertical: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        self.splitView = splitView
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        loaded()
    }
}

/// Files over the File Outline. The files' scroll-edge hairline over the outline's header stands for the divider: AppKit has
/// no thin divider that draws no line, so the divider's own, under the header, isn't drawn, and it takes drags at the hairline.
final class SidebarSplitViewController: SplitViewController {
    weak var header: NSSplitViewItemAccessoryViewController?

    private final class SplitView: NSSplitView {
        override func drawDivider(in rect: NSRect) {}
    }

    init() {
        super.init(splitView: SplitView(), isVertical: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                                   ofDividerAt: dividerIndex)
        // Folded, the outline opens only from its header.
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        // The header's top, in the split view's flipped coordinates.
        let line = header.view.convert(header.view.bounds, to: splitView).minY
        return rect.offsetBy(dx: 0, dy: line - drawnRect.minY)
    }
}

/// The source|PDF divider stops short of the status bar across both panes, and the line over it, at its foot: a split
/// view is flipped.
final class ColumnsSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        var shown = rect
        shown.size.height -= BarMetrics.height + BarMetrics.line
        super.drawDivider(in: shown)
    }
}
