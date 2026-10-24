import SwiftUI
import UIKit

/// The box is a view above the text, which TextKit's selection would cover in the underlay. A tap on it, or near it within
/// a touch's 44 pt, opens the issue; a swipe from it scrolls (`touchesShouldCancel`). VoiceOver has the issues from the
/// text view's rotor.
final class IssueMessageView: UIControl {
    private let hosting: UIHostingController<IssueBox>

    init(_ box: IssueBox) {
        hosting = UIHostingController(rootView: box)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(hosting.view)
        isAccessibilityElement = false
        addAction(UIAction { [unowned self] _ in
            guard let text = superview as? SourceTextView, let row = text.issues.rows.first(where: { $0.message?.view === self })
            else { return }
            text.issues.clicked(row.line)
        }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// As an `NSHostingView`'s, which the Mac's is.
    var rootView: IssueBox {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: min(0, (bounds.width - 44) / 2), dy: min(0, (bounds.height - 44) / 2)).contains(point)
    }
}
