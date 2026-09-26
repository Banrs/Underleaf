import SwiftUI

/// A pane of a `SplitController`: its view, its smallest (and largest)
/// size, the largest share of the split it may take, the share it opens
/// at, whether it keeps its size as the window resizes, and whether it
/// shows.
struct SplitPane {
    var minimum: CGFloat
    var maximum: CGFloat?
    /// At most this share of the split, so a pane that keeps its size gives
    /// way to the others in a small window.
    var maxFraction: CGFloat?
    var fraction: CGFloat?
    var keepsSize = false
    var shown = true
    let content: AnyView

    init(minimum: CGFloat, maximum: CGFloat? = nil, maxFraction: CGFloat? = nil, fraction: CGFloat? = nil,
         keepsSize: Bool = false, shown: Bool = true, @ViewBuilder content: () -> some View) {
        self.minimum = minimum
        self.maximum = maximum
        self.maxFraction = maxFraction
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
    /// room for a merely hidden one); coming back, it gets the share of the
    /// split it had (a pane that keeps its size, that size), or its share
    /// the first time.
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
                    let size = coordinator.hidden[index].map { pane.keepsSize ? $0 : $0 * total }
                        ?? (pane.fraction ?? 0.5) * total
                    split.setPosition(total - size - split.dividerThickness, ofDividerAt: before - 1)
                }
            } else {
                coordinator.hidden[index] = coordinator.share(split, of: index)
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
    /// their sizes, and lays the panes out as the window resizes: each at
    /// its share of the split as last set (by a drag, a pane shown or
    /// hidden, or the autosave), within its sizes. Shares rather than the
    /// sizes the last resize left, so a pane squeezed to its minimum in a
    /// small window gets its share back as the window grows.
    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var panes: [SplitPane] = []
        var views: [NSView] = []
        /// Hidden panes' shares of the split, or sizes for a pane that keeps
        /// its size, by index.
        var hidden: [Int: CGFloat] = [:]
        /// The shown panes' sizes as last set, by index: a pane that keeps
        /// its size keeps this; the others share what is left in proportion.
        private var wanted: [Int: CGFloat] = [:]
        /// The sizes the last resize gave the panes: any others were set
        /// since, and are the ones to keep.
        private var laidOut: [CGFloat] = []

        /// The pane shown at a place in the split.
        private func pane(_ split: NSSplitView, _ place: Int) -> SplitPane {
            panes[views.firstIndex(of: split.arrangedSubviews[place]) ?? place]
        }

        /// The most a pane may take of the split as it is now: its maximum,
        /// or its largest share, whichever is less, and never under its
        /// minimum.
        private func maximum(_ split: NSSplitView, _ pane: SplitPane) -> CGFloat {
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            let share = pane.maxFraction.map { $0 * total } ?? .infinity
            return max(min(pane.maximum ?? .infinity, share), pane.minimum)
        }

        private func span(_ split: NSSplitView, _ place: Int) -> (CGFloat, CGFloat) {
            let frame = split.arrangedSubviews[place].frame
            return split.isVertical ? (frame.minX, frame.maxX) : (frame.minY, frame.maxY)
        }

        private func length(_ split: NSSplitView, _ view: NSView) -> CGFloat {
            split.isVertical ? view.frame.width : view.frame.height
        }

        /// Sizes set since the last resize — a drag, a pane shown or hidden,
        /// the autosave — are the ones to keep.
        private func takeSizes(_ split: NSSplitView) {
            let current = split.arrangedSubviews.map { length(split, $0) }
            guard current.count != laidOut.count || zip(current, laidOut).contains(where: { abs($0 - $1) > 0.5 })
            else { return }
            wanted = [:]
            for (view, size) in zip(split.arrangedSubviews, current) {
                if let index = views.firstIndex(of: view) { wanted[index] = size }
            }
            laidOut = current
        }

        /// What a pane being hidden comes back to: its share of the split
        /// as last set, not whatever a small window squeezed it to; for a
        /// pane that keeps its size, that size.
        func share(_ split: NSSplitView, of index: Int) -> CGFloat? {
            takeSizes(split)
            guard let size = wanted[index] else { return nil }
            return panes[index].keepsSize ? size : size / max(wanted.values.reduce(0, +), 1)
        }

        func splitView(_ split: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            takeSizes(split)
            let shown = split.arrangedSubviews
            let places = shown.indices
            let room = (split.isVertical ? split.bounds.width : split.bounds.height)
                - split.dividerThickness * CGFloat(max(shown.count - 1, 0))
            let limits = places.map { place in
                let pane = pane(split, place)
                return (pane.minimum, maximum(split, pane), pane.keepsSize)
            }
            let want = places.map { place in
                views.firstIndex(of: shown[place]).flatMap { wanted[$0] } ?? length(split, shown[place])
            }
            // Panes that keep their size have it; the rest share what is left.
            let kept = places.filter { limits[$0].2 }.map { want[$0] }.reduce(0, +)
            let shared = places.filter { !limits[$0].2 }.map { want[$0] }.reduce(0, +)
            var sizes = places.map { place in
                limits[place].2 ? want[place] : want[place] / max(shared, 1) * max(room - kept, 0)
            }
            // Within each pane's sizes, the difference settled by the panes
            // that can still give or take: the sharing ones first.
            for place in places { sizes[place] = min(max(sizes[place], limits[place].0), limits[place].1) }
            var excess = sizes.reduce(0, +) - room
            for keeps in [false, true] {
                for place in places.reversed() where limits[place].2 == keeps && excess != 0 {
                    let change = excess > 0
                        ? min(excess, sizes[place] - limits[place].0)
                        : max(excess, sizes[place] - limits[place].1)
                    sizes[place] -= change
                    excess -= change
                }
            }
            // Too small for every minimum: the last pane gives the rest.
            if let last = places.last { sizes[last] -= excess }

            var offset: CGFloat = 0
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            for place in places {
                // The last to the end, whatever the rounding left.
                let size = place == places.last ? total - offset : sizes[place].rounded()
                shown[place].frame = split.isVertical
                    ? NSRect(x: offset, y: 0, width: size, height: split.bounds.height)
                    : NSRect(x: 0, y: offset, width: split.bounds.width, height: size)
                offset += size + split.dividerThickness
            }
            laidOut = shown.map { length(split, $0) }
        }

        /// A pane that keeps its size leaves a window resize to the others.
        func splitView(_ split: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            guard let index = views.firstIndex(of: view) else { return true }
            return !panes[index].keepsSize
        }

        func splitView(_ split: NSSplitView, constrainMinCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            let low = max(span(split, place).0 + pane(split, place).minimum,
                          span(split, place + 1).1 - maximum(split, pane(split, place + 1)))
            return max(proposed, low)
        }

        func splitView(_ split: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            let high = min(span(split, place + 1).1 - pane(split, place + 1).minimum,
                           span(split, place).0 + maximum(split, pane(split, place)))
            return min(proposed, high)
        }
    }
}
