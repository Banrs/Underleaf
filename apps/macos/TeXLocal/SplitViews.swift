import AppKit
import PDFKit

extension NSView {
    @discardableResult
    func updateDividerCursor(with event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, let workspace = window.contentView, let content = workspace.superview,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
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
        if hit is NSScroller { NSCursor.arrow.set(); return true }
        if let pdf = sequence(first: hit, next: \.superview).first(where: { $0 is PDFView }) as? PDFView, self is NSTextView || resizing {
            pdf.setCursorFor(pdf.areaOfInterest(forMouse: event))
            return true
        }
        if resizing { (hit is NSTextView || hit is NSTextField ? NSCursor.iBeam : .arrow).set() }
        return false
    }

    func isDoubleClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2, let up = NSApp.currentEvent, up.type == .leftMouseUp else { return false }
        return abs(up.locationInWindow.x - event.locationInWindow.x) <= 4 && abs(up.locationInWindow.y - event.locationInWindow.y) <= 4
    }

    func descendants<View: NSView>(of type: View.Type) -> [View] {
        [self as? View].compactMap(\.self) + subviews.flatMap { $0.descendants(of: type) }
    }
}

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

class ThinSplitViewController: NSSplitViewController {
    init(splitView: DraggedSplitView = DraggedSplitView(), isVertical: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        self.splitView = splitView
    }

    required init?(coder: NSCoder) { fatalError() }

    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard let columns = splitView as? ColumnsSplitView, columns.dragging,
              abs(proposedPosition - columns.evenPosition) <= 8 else { return proposedPosition }
        if abs(columns.arrangedSubviews[0].frame.maxX - columns.evenPosition) >= 0.5 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        return columns.evenPosition
    }
}

final class SidebarSplitViewController: ThinSplitViewController {
    weak var header: NSSplitViewItemAccessoryViewController?

    private final class SplitView: DraggedSplitView { override func drawDivider(in rect: NSRect) {} }

    init() { super.init(splitView: SplitView(), isVertical: false) }

    required init?(coder: NSCoder) { fatalError() }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        return rect.offsetBy(dx: 0, dy: header.view.convert(header.view.bounds, to: splitView).minY - drawnRect.minY)
    }
}

final class ColumnsSplitView: DraggedSplitView {
    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - BarMetrics.height))
    }

    var evenPosition: CGFloat { ((bounds.width - dividerThickness) * (1 - ColumnMetrics.pdfShare)).rounded() }
}

extension NSScrollView {
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
