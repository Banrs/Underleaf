import AppKit
import SwiftUI

/// TextKit's selection view would cover a box drawn in the text view's background, so the box is a view above the text's,
/// which takes no click.
final class IssueMessageView: NSHostingView<IssueBox> {
    convenience init(_ box: IssueBox) {
        self.init(rootView: box)
        sizingOptions = []
        safeAreaRegions = []
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
