import AppKit
import PDFKit

extension NSView {
    /// TextKit and PDFKit still take tracking events just inside the panes and replace the divider's cursor, so only the
    /// divider's own hit target chooses the resize cursor.
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

    func descendants(named name: String) -> [NSView] {
        subviews.flatMap { ($0.className == name ? [$0] : []) + $0.descendants(named: name) }
    }

    func descendants<View: NSView>(of type: View.Type) -> [View] {
        [self as? View].compactMap(\.self) + subviews.flatMap { $0.descendants(of: type) }
    }
}

/// AppKit tracks a divider's drag within the press on it, the only place a split view itself is hit.
class DraggedSplitView: NSSplitView {
    private(set) var dragging = false

    override func mouseDown(with event: NSEvent) {
        let workspace = window?.contentViewController as? WorkspaceController
        dragging = true
        workspace?.quiet(true)
        defer {
            dragging = false
            workspace?.quiet(false)
        }
        super.mouseDown(with: event)
    }
}

/// Thin dividers, and the detents AppKit's splits lack: a drag that comes near a divider's opening position stops there,
/// with the alignment haptic as it arrives.
class DetentSplitViewController: NSSplitViewController {
    init(splitView: DraggedSplitView = DraggedSplitView(), isVertical: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        self.splitView = splitView
    }

    required init?(coder: NSCoder) { fatalError() }

    func detent(at divider: Int) -> CGFloat? { (splitView as? ColumnsSplitView)?.openingPosition }

    /// Only while a divider is dragged: a position set in code goes where it is set. 27.2: NSSplitViewController
    /// declares this without implementing it, so there is no super to call.
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard (splitView as? DraggedSplitView)?.dragging == true, let detent = detent(at: dividerIndex),
              abs(proposedPosition - detent) <= ColumnMetrics.detentReach else { return proposedPosition }
        let pane = splitView.arrangedSubviews[dividerIndex].frame
        if abs((splitView.isVertical ? pane.maxX : pane.maxY) - detent) >= 0.5 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        return detent
    }
}

/// Files over the File Outline. AppKit has no thin divider without a line, so the divider isn't drawn: the files' scroll
/// edge over the outline's header stands for it, and takes its drags.
final class SidebarSplitViewController: DetentSplitViewController {
    weak var header: NSSplitViewItemAccessoryViewController?

    private final class SplitView: DraggedSplitView { override func drawDivider(in rect: NSRect) {} }

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

final class ColumnsSplitView: DraggedSplitView {
    /// Short of the status bar, whose line is AppKit's scroll edge's. A split view is flipped.
    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - BarMetrics.height))
    }

    /// A double-click on the divider, which takes presses 2 pt either side of its line, restores the even split. 27.2: the
    /// items' preferred fractions land it somewhere else each time.
    override func mouseDown(with event: NSEvent) {
        let past = convert(event.locationInWindow, from: nil).x - (arrangedSubviews.first?.frame.maxX ?? 0)
        guard event.clickCount == 2, -2...dividerThickness + 2 ~= past, arrangedSubviews.allSatisfy({ !isSubviewCollapsed($0) }) else {
            return super.mouseDown(with: event)
        }
        setPosition(openingPosition, ofDividerAt: 0)
    }

    var openingPosition: CGFloat { ((bounds.width - dividerThickness) * (1 - ColumnMetrics.pdfShare)).rounded() }
}

extension NSScrollView {
    /// Shown again, a scroller is swapped out and in, which resets AppKit's fade: it stays hidden until the next scroll.
    func hideOverlayScrollers(_ hidden: Bool) {
        guard scrollerStyle == .overlay else { return }
        for key in [\NSScrollView.verticalScroller, \NSScrollView.horizontalScroller] {
            guard let scroller = self[keyPath: key] else { continue }
            if !hidden {
                self[keyPath: key] = NSScroller()
                self[keyPath: key] = scroller
            }
            scroller.alphaValue = hidden ? 0 : 1
        }
    }
}
