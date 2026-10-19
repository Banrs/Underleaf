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
        if NSCursor.isResizingColumn { (hit is NSTextView || hit is NSTextField ? NSCursor.iBeam : .arrow).set() }
        return false
    }
}

extension NSCursor {
    static var isResizingColumn: Bool {
        current == .columnResize || current == .columnResize(directions: .left) || current == .columnResize(directions: .right)
    }
}

/// A split view that says when a divider is dragged: AppKit tracks the drag within the press on a divider, the only place
/// the split itself is hit.
class DraggedSplitView: NSSplitView {
    var dragging: (Bool) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        dragging(true)
        defer { dragging(false) }
        super.mouseDown(with: event)
    }
}

/// Thin dividers; `loaded` puts back what the models say over the collapses the autosave restores as it loads. AppKit has
/// no split detents: a drag that comes near `detent`, a divider's
/// opening position, stops there, with the alignment haptic as it arrives.
class DetentSplitViewController: NSSplitViewController {
    var loaded: () -> Void = {}
    var detent: (_ divider: Int) -> CGFloat? = { _ in nil }
    /// A divider that takes no drag, and so shows no resize cursor.
    var fixed: (_ divider: Int) -> Bool = { _ in false }
    /// As a divider's drag starts, and as it ends.
    var dragging: (Bool) -> Void = { _ in }
    /// Where a divider also takes drags, over the panes' own views: the split hit-tests it before them.
    var grip: (_ divider: Int) -> NSRect = { _ in .zero }

    init(splitView: DraggedSplitView = DraggedSplitView(), isVertical: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        splitView.dragging = { [unowned self] in dragging($0) }
        self.splitView = splitView
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        loaded()
    }

    /// 27.2: NSSplitViewController declares this, as the split's delegate, without implementing it, so there is no super to call.
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard let detent = detent(dividerIndex),
              abs(proposedPosition - detent) <= ColumnMetrics.detentReach else { return proposedPosition }
        // Once, as the divider arrives: not on each step of a drag held there.
        let pane = splitView.arrangedSubviews[dividerIndex].frame
        if abs((splitView.isVertical ? pane.maxX : pane.maxY) - detent) >= 0.5 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        return detent
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        fixed(dividerIndex) ? .zero
            : super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }

    override func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, additionalEffectiveRectOfDividerAt: dividerIndex)
        return grip(dividerIndex).isEmpty ? rect : grip(dividerIndex)
    }
}

/// Files over the File Outline. The files' scroll-edge hairline over the outline's header stands for the divider: AppKit has
/// no thin divider that draws no line, so the divider's own, under the header, isn't drawn, and it takes drags at the hairline.
final class SidebarSplitViewController: DetentSplitViewController {
    weak var header: NSSplitViewItemAccessoryViewController?

    private final class SplitView: DraggedSplitView { override func drawDivider(in rect: NSRect) {} }

    init() { super.init(splitView: SplitView(), isVertical: false) }

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

final class ColumnsSplitView: DraggedSplitView {
    /// Short of the status bar across both panes, whose line is AppKit's scroll edge's, at its foot: a split view is flipped.
    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - BarMetrics.height))
    }

    /// A double-click on the divider restores the even split. 27.2: the items' preferred fractions, AppKit's own way, land
    /// the divider somewhere else each time.
    override func mouseDown(with event: NSEvent) {
        // On the divider, which takes presses 2 pt either side of its line: a pane passes up its own.
        let past = convert(event.locationInWindow, from: nil).x - (arrangedSubviews.first?.frame.maxX ?? 0)
        guard event.clickCount == 2, -2...dividerThickness + 2 ~= past, arrangedSubviews.allSatisfy({ !isSubviewCollapsed($0) }) else {
            return super.mouseDown(with: event)
        }
        setPosition(openingPosition, ofDividerAt: 0)
    }

    var openingPosition: CGFloat { ((bounds.width - dividerThickness) * (1 - ColumnMetrics.pdfShare)).rounded() }
}

extension NSView {
    /// Every view under this one whose class has the name.
    func descendants(named name: String) -> [NSView] {
        subviews.flatMap { ($0.className == name ? [$0] : []) + $0.descendants(named: name) }
    }

    /// Every view of the type under this one, and this one if it is.
    func descendants<View: NSView>(of type: View.Type) -> [View] {
        [self as? View].compactMap(\.self) + subviews.flatMap { $0.descendants(of: type) }
    }
}

extension NSScrollView {
    /// Out of sight, or back without flashing: a scroller shown again is swapped out and in, which resets AppKit's
    /// fade, so it stays hidden until the next scroll.
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
