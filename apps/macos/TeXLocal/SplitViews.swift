import AppKit
import PDFKit

extension NSView {
    /// TextKit and PDFKit take tracking events just inside the panes and replace the divider's cursor.
    @discardableResult
    func updateDividerCursor(with event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, let workspace = window.contentView, let content = workspace.superview,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        // The toolbar sets its own cursors.
        guard hit.isDescendant(of: workspace) else { return true }
        let resizing = [NSCursor.columnResize, .columnResize(directions: .left), .columnResize(directions: .right)].contains(NSCursor.current)
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
        // NSTextView also takes mouse moves over its overlay scroller and, while first responder, over the PDF.
        if hit is NSScroller { NSCursor.arrow.set(); return true }
        if let pdf = sequence(first: hit, next: \.superview).first(where: { $0 is PDFView }) as? PDFView, self is NSTextView || resizing {
            pdf.setCursorFor(pdf.areaOfInterest(forMouse: event))
            return true
        }
        // Leaving the divider need not enter another tracking area.
        if resizing { (hit is NSTextView || hit is NSTextField ? NSCursor.iBeam : .arrow).set() }
        return false
    }

    func descendants<View: NSView>(of type: View.Type) -> [View] {
        [self as? View].compactMap(\.self) + subviews.flatMap { $0.descendants(of: type) }
    }
}

/// Thin dividers, AppKit's default, which a split view of its own would otherwise lose.
class ThinSplitViewController: NSSplitViewController {
    init(splitView: NSSplitView = NSSplitView(), isVertical: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        self.splitView = splitView
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Files over the File Outline. AppKit has no thin divider without a line: the files' scroll edge stands for it.
final class SidebarSplitViewController: ThinSplitViewController {
    weak var header: NSSplitViewItemAccessoryViewController?

    private final class SplitView: NSSplitView { override func drawDivider(in rect: NSRect) {} }

    init() { super.init(splitView: SplitView(), isVertical: false) }

    required init?(coder: NSCoder) { fatalError() }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        // Folded, the outline opens only from its header.
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        return rect.offsetBy(dx: 0, dy: header.view.convert(header.view.bounds, to: splitView).minY - drawnRect.minY)
    }
}

final class ColumnsSplitView: NSSplitView {
    /// Short of the status bar, whose line is AppKit's scroll edge's. A split view is flipped.
    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - BarMetrics.height))
    }
}
