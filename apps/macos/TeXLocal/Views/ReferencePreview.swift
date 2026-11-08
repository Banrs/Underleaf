import AppKit
import PDFKit
import SwiftUI

/// What a label names, cut from the shown PDF.
struct ReferencePicture {
    let image: NSImage
    let darkPaper: Bool

    static let maxSize = CGSize(width: 420, height: 300)
}

extension PDFController {
    func picture(of loc: ForwardLoc, scale: CGFloat) -> ReferencePicture? {
        guard let page = view.document?.page(number: Int(loc.page)) else { return nil }
        let bounds = page.bounds(for: SyncPDFView.box)
        guard let box = SyncTeXGeometry.area(loc, pageBounds: bounds) else { return nil }
        let margin: CGFloat = 6
        let area = box.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        guard area.width > 1, area.height > 1 else { return nil }
        let zoom = min(1.5, ReferencePicture.maxSize.width / area.width, ReferencePicture.maxSize.height / area.height)
        let size = CGSize(width: (area.width * zoom).rounded(), height: (area.height * zoom).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        context.scaleBy(x: zoom * scale, y: zoom * scale)
        // `draw(with:to:)` puts the box's corner at the origin.
        context.translateBy(x: bounds.minX - area.minX, y: bounds.minY - area.minY)
        page.draw(with: SyncPDFView.box, to: context)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return ReferencePicture(image: image, darkPaper: view.darkPaper)
    }
}

struct ReferencePictureView: View {
    let picture: ReferencePicture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Image(nsImage: picture.image)
            .colorInverted(picture.darkPaper)
            .frame(width: picture.image.size.width, height: picture.image.size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator) }
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder func colorInverted(_ inverted: Bool) -> some View {
        // As the PDF view shows dark paper.
        if inverted { colorInvert().hueRotation(.degrees(180)) } else { self }
    }
}

/// Quick Help for the reference or citation the pointer rests on: shown after a pause, and closed once the pointer
/// leaves both the key and the popover, or on a key press, click or scroll.
@MainActor
final class HoverHelp {
    private unowned let text: SourceTextView
    private let popover = NSPopover()
    private var resting: Task<Void, Never>?
    private var monitor: Any?
    /// The key the pointer rests on, in the text view's coordinates.
    private var anchor: (range: NSRange, rect: NSRect)?

    init(for text: SourceTextView) {
        self.text = text
        popover.behavior = .applicationDefined
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func moved(to point: NSPoint) {
        if let anchor, anchor.rect.contains(point) { return }
        close()
        resting = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { self?.rested() }
        }
    }

    /// Leaving the text view for the popover keeps it.
    func exited() {
        if popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) != true { close() }
    }

    private func rested() {
        // A key pressed since the pointer stopped means it rests by chance while typing.
        guard let window = text.window, window.isKeyWindow,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 0.5,
              let key = text.referenceKey(at: text.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        anchor = key
        text.quickHelp(key.range.location, true)
    }

    /// Shows help that was asked for at `offset`, if the pointer is still on its key.
    func show(_ content: NSViewController, at offset: Int) {
        guard let anchor, NSLocationInRange(offset, anchor.range), text.window?.isVisible == true else { return }
        popover.contentViewController = content
        popover.show(relativeTo: anchor.rect, of: text, preferredEdge: .maxY)
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown,
                                                                         .scrollWheel]) { [weak self] event in
            self?.heard(event)
            return event
        }
    }

    private func heard(_ event: NSEvent) {
        let inPopover = popover.contentViewController?.view.window.map { $0.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) }
        switch event.type {
        case .mouseMoved where inPopover == true: break
        case .mouseMoved where event.window === text.window:
            if let anchor, !anchor.rect.contains(text.convert(event.locationInWindow, from: nil)) { close() }
        case .leftMouseDown, .rightMouseDown: if inPopover != true { close() }
        default: close()
        }
    }

    func close() {
        resting?.cancel()
        resting = nil
        anchor = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if popover.isShown { popover.close() }
    }
}

extension SourceTextView {
    /// The label or citation key under `point`, if the pointer is on its text.
    func referenceKey(at point: NSPoint) -> (range: NSRange, rect: NSRect)? {
        guard let window, point.x >= textContainerOrigin.x else { return nil }
        let index = characterIndexForInsertion(at: point)
        let rect = { (range: NSRange) in self.convert(window.convertFromScreen(self.firstRect(forCharacterRange: range, actualRange: nil)), from: nil) }
        guard let at = [index, index - 1].first(where: { $0 >= 0 && $0 < length && rect(NSRange(location: $0, length: 1)).contains(point) }),
              let symbol = document.symbol(at: at), symbol.kind == .label || symbol.kind == .citation else { return nil }
        let stops = CharacterSet(charactersIn: "{},\\%").union(.whitespacesAndNewlines)
        let text = source
        var start = at, end = at
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), !stops.contains(scalar) { start -= 1 }
        while end < length, let scalar = Unicode.Scalar(text.character(at: end)), !stops.contains(scalar) { end += 1 }
        guard end > start else { return nil }
        let range = NSRange(location: start, length: end - start)
        return (range, rect(range).insetBy(dx: -2, dy: -2))
    }
}
