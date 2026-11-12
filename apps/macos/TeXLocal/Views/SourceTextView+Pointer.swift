import AppKit

extension SourceTextView {
    private func setsCursor(with event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let overGutter = inGutter(point, before: sourceTextStart)
        gutterHover(overGutter)
        let overControl = overGutter && (point.x < gutter.numbersEnd || foldLine(at: point) != nil)
        guard overControl || issue(at: event) != nil else { return false }
        NSCursor.arrow.set()
        return true
    }

    private func inGutter(_ point: NSPoint, before edge: CGFloat) -> Bool {
        visibleRect.contains(point) && point.x < edge
    }

    private func issue(at event: NSEvent) -> IssueOverlay.Row? { issues.message(at: convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) {
        guard !setsCursor(with: event) else { return hoverHelp.close() }
        super.mouseMoved(with: event)
        hoverHelp.moved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { if !setsCursor(with: event) { super.mouseEntered(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if !setsCursor(with: event) { super.cursorUpdate(with: event) } }

    override func mouseExited(with event: NSEvent) {
        gutterHover(false)
        hoverHelp.exited()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown {
            let point = convert(event.locationInWindow, from: nil)
            if foldClick(at: point) || inGutter(point, before: gutter.numbersEnd) { return }
        }
        let held = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.type == .leftMouseDown, held.isEmpty, let row = issue(at: event), let up = release(of: event) {
            if row.message?.rect.contains(convert(up.locationInWindow, from: nil)) == true { issues.clicked(row.line) }
            return
        }
        if event.type == .leftMouseDown, held == .command,
           let place = document.definition(at: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))?.places.first,
           release(of: event) != nil {
            return openDefinition(place)
        }
        if event.type == .leftMouseDown, held == .option, release(of: event) != nil {
            return quickHelp(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), false)
        }
        super.mouseDown(with: event)
        if isDoubleClick(event), !document.selectsCommand(selectedRange()) { forwardSync(true)?() }
    }

    private func release(of down: NSEvent) -> NSEvent? {
        guard down.clickCount == 1 else { return nil }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return next }
            if hypot(next.locationInWindow.x - down.locationInWindow.x, next.locationInWindow.y - down.locationInWindow.y) > 3 {
                window?.postEvent(next, atStart: true)
                return nil
            }
        }
        return nil
    }
}
