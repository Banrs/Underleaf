import SwiftUI

/// A pane of a `SplitController`: its view, its smallest (and largest)
/// size, the share of the split it opens at, whether it keeps its size as
/// the window resizes, and whether it shows.
struct SplitPane {
    var minimum: CGFloat
    var maximum: CGFloat?
    var fraction: CGFloat?
    var keepsSize = false
    var shown = true
    let content: AnyView

    init(minimum: CGFloat, maximum: CGFloat? = nil, fraction: CGFloat? = nil, keepsSize: Bool = false,
         shown: Bool = true, @ViewBuilder content: () -> some View) {
        self.minimum = minimum
        self.maximum = maximum
        self.fraction = fraction
        self.keepsSize = keepsSize
        self.shown = shown
        self.content = AnyView(content())
    }
}

/// AppKit's split view: its dividers and resize pointers, a pane that hides
/// collapsing with its divider, and divider positions remembered under
/// `autosave`.
///
/// Not SwiftUI's: HSplitView and VSplitView laid their panes out past their
/// bounds, and `.inspector` crashed the window on resize ("more Update
/// Constraints passes than views"). Not NSSplitViewController either: it
/// blurs the top of each pane under the toolbar, where the pane bars sit.
struct SplitController: NSViewRepresentable {
    let app: AppModel
    let axis: Axis
    let autosave: String
    let panes: [SplitPane]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = axis == .horizontal
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        context.coordinator.panes = panes
        let rest = 1 - panes.compactMap(\.fraction).reduce(0, +)
        for pane in panes {
            // Made once: the views observe the models themselves.
            let host = NSHostingView(rootView: AnyView(pane.content.environment(app)))
            // SwiftUI's sizes stay out of Auto Layout; the delegate keeps
            // each pane within its minimum and maximum instead.
            host.sizingOptions = []
            // Starting sizes in proportion, until the split has its own.
            let share = (pane.fraction ?? rest) * 1000
            host.frame.size = axis == .horizontal
                ? CGSize(width: share, height: 1000) : CGSize(width: 1000, height: share)
            context.coordinator.views.append(host)
            if pane.shown { split.addArrangedSubview(host) }
        }
        split.autosaveName = autosave
        return split
    }

    /// Shows and hides panes. A hidden pane leaves the split (AppKit kept
    /// room for a merely hidden one); coming back, it gets the size it had,
    /// or its share the first time.
    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.panes = panes
        for (index, (view, pane)) in zip(coordinator.views, panes).enumerated() where (view.superview === split) != pane.shown {
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            if pane.shown {
                let before = coordinator.views[..<index].filter { $0.superview === split }.count
                split.insertArrangedSubview(view, at: before)
                split.adjustSubviews()
                if before > 0 {
                    let size = coordinator.sizes[index] ?? (pane.fraction ?? 0.5) * total
                    split.setPosition(total - size - split.dividerThickness, ofDividerAt: before - 1)
                }
            } else {
                coordinator.sizes[index] = split.isVertical ? view.frame.width : view.frame.height
                split.removeArrangedSubview(view)
                view.removeFromSuperview()
                split.adjustSubviews()
            }
        }
    }

    /// The whole proposal: the split fills its place, and its panes'
    /// minimums don't reach the window's layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// Keeps a dragged divider where both panes beside it stay within
    /// their sizes.
    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var panes: [SplitPane] = []
        var views: [NSView] = []
        /// The sizes of hidden panes, by index.
        var sizes: [Int: CGFloat] = [:]

        /// The pane shown at a place in the split.
        private func pane(_ split: NSSplitView, _ place: Int) -> SplitPane {
            panes[views.firstIndex(of: split.arrangedSubviews[place]) ?? place]
        }

        private func span(_ split: NSSplitView, _ place: Int) -> (CGFloat, CGFloat) {
            let frame = split.arrangedSubviews[place].frame
            return split.isVertical ? (frame.minX, frame.maxX) : (frame.minY, frame.maxY)
        }

        /// A pane that keeps its size leaves a window resize to the others.
        func splitView(_ split: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            guard let index = views.firstIndex(of: view) else { return true }
            return !panes[index].keepsSize
        }

        func splitView(_ split: NSSplitView, constrainMinCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            var low = span(split, place).0 + pane(split, place).minimum
            if let maximum = pane(split, place + 1).maximum { low = max(low, span(split, place + 1).1 - maximum) }
            return max(proposed, low)
        }

        func splitView(_ split: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            var high = span(split, place + 1).1 - pane(split, place + 1).minimum
            if let maximum = pane(split, place).maximum { high = min(high, span(split, place).0 + maximum) }
            return min(proposed, high)
        }
    }
}
