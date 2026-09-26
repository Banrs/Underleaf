import SwiftUI

/// A pane of a `SplitController`.
struct SplitPane {
    var minimum: CGFloat
    var maximum: CGFloat?
    /// At most this share of the split, so a pane that keeps its size gives
    /// way to the others in a small window.
    var maxFraction: CGFloat?
    /// The share it opens at.
    var fraction: CGFloat?
    /// Keeps its size as the window resizes.
    var keepsSize = false
    var shown = true
    /// On edge-to-edge system glass, as an inspector sits beside the
    /// content (`NSGlassEffectView`, the pane its content view).
    var glass = false
    /// Folded to this size (its header), its divider fixed; unfolding
    /// brings back the size it had, remembered across launches.
    var collapsed: CGFloat?
    let content: AnyView

    init(minimum: CGFloat, maximum: CGFloat? = nil, maxFraction: CGFloat? = nil, fraction: CGFloat? = nil,
         keepsSize: Bool = false, shown: Bool = true, glass: Bool = false, collapsed: CGFloat? = nil,
         @ViewBuilder content: () -> some View) {
        self.minimum = minimum
        self.maximum = maximum
        self.maxFraction = maxFraction
        self.fraction = fraction
        self.keepsSize = keepsSize
        self.shown = shown
        self.glass = glass
        self.collapsed = collapsed
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

    func makeCoordinator() -> Coordinator { Coordinator(autosave: autosave) }

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
            let clip = PaneClip(content: host, vertical: split.isVertical)
            context.coordinator.clips.append(clip)
            let view: NSView
            if pane.glass {
                // The content inside the glass, never a sibling behind it.
                let glass = NSGlassEffectView()
                glass.cornerRadius = 0
                glass.contentView = clip
                view = glass
            } else {
                view = clip
            }
            // Starting sizes in proportion, until the split has its own.
            let share = (pane.fraction ?? rest) * 1000
            view.frame.size = axis == .horizontal
                ? CGSize(width: share, height: 1000) : CGSize(width: 1000, height: share)
            context.coordinator.views.append(view)
            if pane.shown { split.addArrangedSubview(view) }
        }
        split.autosaveName = autosave
        return split
    }

    /// Shows and hides panes. A hidden pane leaves the split (AppKit kept
    /// room for a merely hidden one); coming back, it gets the share of the
    /// split it had (a pane that keeps its size, that size), or its share
    /// the first time. Folds and unfolds panes too (`SplitPane.collapsed`).
    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        let was = coordinator.panes
        coordinator.panes = panes
        for (index, (view, pane)) in zip(coordinator.views, panes).enumerated() {
            let before = was.indices.contains(index) ? was[index].collapsed : pane.collapsed
            if before != pane.collapsed, pane.shown, view.superview === split {
                coordinator.fold(split, index, to: pane.collapsed, keeping: before == nil)
            }
        }
        for (index, (view, pane)) in zip(coordinator.views, panes).enumerated() {
            // A pane sliding shut still sits in the split until it's closed.
            let hiding = coordinator.hiding.contains(index)
            guard (view.superview === split && !hiding) != pane.shown else { continue }
            let total = split.length
            let closed = total - split.dividerThickness
            if pane.shown {
                let place: Int
                if hiding, let at = split.arrangedSubviews.firstIndex(of: view) {
                    coordinator.hiding.remove(index)
                    place = at
                } else {
                    place = coordinator.views[..<index].filter { $0.superview === split }.count
                    split.insertArrangedSubview(view, at: place)
                    split.adjustSubviews()
                    // It opens from nothing.
                    if place > 0 { coordinator.slide(split, divider: place - 1, to: closed, animated: false) }
                }
                if place > 0 {
                    let size = pane.collapsed
                        ?? coordinator.hidden[index].map { pane.keepsSize ? $0 : $0 * total }
                        ?? (pane.fraction ?? 0.5) * total
                    // Laid out at the size it opens to, and slid in whole.
                    let clip = coordinator.clips[index]
                    clip.pinned = size
                    coordinator.slide(split, divider: place - 1, to: total - size - split.dividerThickness) {
                        clip.pinned = nil
                    }
                }
            } else {
                coordinator.hidden[index] = coordinator.share(split, of: index)
                let remove = { [weak split] in
                    view.removeFromSuperview()
                    split?.adjustSubviews()
                }
                guard let place = split.arrangedSubviews.firstIndex(of: view), place > 0 else {
                    remove()
                    continue
                }
                coordinator.hiding.insert(index)
                // Slid out whole, at the size it had.
                let clip = coordinator.clips[index]
                clip.pinned = split.length(of: view)
                coordinator.slide(split, divider: place - 1, to: closed) {
                    clip.pinned = nil
                    // Shown again while it closed: it stays.
                    guard coordinator.hiding.remove(index) != nil else { return }
                    remove()
                }
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
        let autosave: String
        var panes: [SplitPane] = []
        var views: [NSView] = []
        /// Each pane's content, by index, inside its view.
        var clips: [PaneClip] = []
        /// Hidden panes' shares of the split, or sizes for a pane that keeps
        /// its size, by index.
        var hidden: [Int: CGFloat] = [:]
        /// The shown panes' sizes as last set, by index: a pane that keeps
        /// its size keeps this; the others share what is left in proportion.
        private var wanted: [Int: CGFloat] = [:]
        /// The sizes the last resize gave the panes: any others were set
        /// since, and are the ones to keep.
        private var laidOut: [CGFloat] = []

        /// Panes sliding shut, by index: still in the split until closed.
        var hiding: Set<Int> = []
        /// A divider moving: the limits stand aside until it arrives.
        private var sliding: (timer: Timer, finish: () -> Void)?
        /// A divider set where a slide puts it, at once: the limits stand
        /// aside for that too, so a pane opens from nothing, not its
        /// minimum.
        private var placing = false
        private var free: Bool { sliding != nil || placing }

        init(autosave: String) {
            self.autosave = autosave
        }

        /// Moves a divider to `position` as the system slides a pane, eased
        /// over a quarter second (at once off screen or with Reduce Motion),
        /// then runs `done`. A slide under way arrives first.
        func slide(_ split: NSSplitView, divider: Int, to position: CGFloat, animated: Bool = true,
                   done: @escaping () -> Void = {}) {
            sliding?.timer.invalidate()
            sliding?.finish()
            let from = span(split, divider).1
            let finish = { [weak self, weak split] in
                self?.sliding = nil
                self?.placing = true
                split?.setPosition(position, ofDividerAt: divider)
                self?.placing = false
                done()
            }
            guard animated, abs(position - from) > 1, split.window?.isVisible == true,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                finish()
                return
            }
            let start = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self, weak split] timer in
                let t = min((CACurrentMediaTime() - start) / 0.25, 1)
                if t >= 1 || self == nil || split == nil { timer.invalidate() }
                MainActor.assumeIsolated {
                    guard let self, let split else { return }
                    guard t < 1 else {
                        self.sliding?.finish()
                        return
                    }
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(2 - 2 * t, 2) / 2
                    split.setPosition(from + (position - from) * eased, ofDividerAt: divider)
                }
            }
            sliding = (timer, finish)
            RunLoop.main.add(timer, forMode: .common)
        }

        /// Where a folded pane's unfolded size is kept: the split's own
        /// autosave holds the folded one.
        private func unfoldedKey(_ index: Int) -> String { "\(autosave) Unfolded \(index)" }

        /// Folds a pane to `size`, keeping the size it had to come back
        /// to (`keeping`: it was unfolded), or (`size` nil) unfolds it to
        /// that size. Only a pane after the first: it moves the divider
        /// before it.
        func fold(_ split: NSSplitView, _ index: Int, to size: CGFloat?, keeping: Bool = true) {
            let view = views[index]
            guard let place = split.arrangedSubviews.firstIndex(of: view), place > 0 else { return }
            let end = span(split, place).1
            let target: CGFloat
            if let size {
                if keeping { UserDefaults.standard.set(Double(split.length(of: view)), forKey: unfoldedKey(index)) }
                target = size
            } else {
                let kept = UserDefaults.standard.double(forKey: unfoldedKey(index))
                let pane = panes[index]
                target = kept > pane.minimum ? kept : (pane.fraction ?? 0.5) * split.length
            }
            slide(split, divider: place - 1, to: end - target - split.dividerThickness) { [weak split] in
                split?.adjustSubviews()
            }
        }

        /// The pane shown at a place in the split.
        private func pane(_ split: NSSplitView, _ place: Int) -> SplitPane {
            panes[views.firstIndex(of: split.arrangedSubviews[place]) ?? place]
        }

        /// The most a pane may take of the split as it is now: its maximum,
        /// or its largest share, whichever is less, and never under its
        /// minimum.
        private func maximum(_ split: NSSplitView, _ pane: SplitPane) -> CGFloat {
            if let folded = pane.collapsed { return folded }
            let share = pane.maxFraction.map { $0 * split.length } ?? .infinity
            return max(min(pane.maximum ?? .infinity, share), pane.minimum)
        }

        /// The least a pane may take: its folded size while folded.
        private func minimum(_ pane: SplitPane) -> CGFloat { pane.collapsed ?? pane.minimum }

        private func span(_ split: NSSplitView, _ place: Int) -> (CGFloat, CGFloat) {
            let frame = split.arrangedSubviews[place].frame
            return split.isVertical ? (frame.minX, frame.maxX) : (frame.minY, frame.maxY)
        }

        /// Sizes set since the last resize — a drag, a pane shown or hidden,
        /// the autosave — are the ones to keep.
        private func takeSizes(_ split: NSSplitView) {
            let current = split.arrangedSubviews.map(split.length(of:))
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
            let room = split.length - split.dividerThickness * CGFloat(max(shown.count - 1, 0))
            let limits = places.map { place in
                let pane = pane(split, place)
                // A pane sliding open or shut passes under its minimum.
                return (free ? 0 : minimum(pane), maximum(split, pane),
                        pane.keepsSize || pane.collapsed != nil)
            }
            let want = places.map { place in
                views.firstIndex(of: shown[place]).flatMap { wanted[$0] } ?? split.length(of: shown[place])
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
            for place in places {
                // The last to the end, whatever the rounding left.
                let size = place == places.last ? split.length - offset : sizes[place].rounded()
                shown[place].frame = split.isVertical
                    ? NSRect(x: offset, y: 0, width: size, height: split.bounds.height)
                    : NSRect(x: 0, y: offset, width: split.bounds.width, height: size)
                offset += size + split.dividerThickness
            }
            laidOut = shown.map(split.length(of:))
        }

        /// A pane that keeps its size leaves a window resize to the others.
        func splitView(_ split: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            guard let index = views.firstIndex(of: view) else { return true }
            return !panes[index].keepsSize && panes[index].collapsed == nil
        }

        /// A folded pane's divider doesn't drag, and shows no resize pointer.
        func splitView(_ split: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect,
                       ofDividerAt place: Int) -> NSRect {
            let beside = [place, place + 1].filter(split.arrangedSubviews.indices.contains)
            return free || beside.contains { pane(split, $0).collapsed != nil } ? .zero : proposed
        }

        // The divider's position is where the pane before it ends; the pane
        // after it starts a divider's thickness later.
        func splitView(_ split: NSSplitView, constrainMinCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            if free { return proposed }
            let low = max(span(split, place).0 + minimum(pane(split, place)),
                          span(split, place + 1).1 - maximum(split, pane(split, place + 1)) - split.dividerThickness)
            return max(proposed, low)
        }

        func splitView(_ split: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
                       ofSubviewAt place: Int) -> CGFloat {
            if free { return proposed }
            let high = min(span(split, place + 1).1 - minimum(pane(split, place + 1)) - split.dividerThickness,
                           span(split, place).0 + maximum(split, pane(split, place)))
            return min(proposed, high)
        }
    }
}

/// A pane's content, laid out at `pinned` along the split while the pane
/// slides open or shut, so it slides in and out whole rather than
/// rewrapping at every width, as the system's inspectors and sidebars do;
/// clipped where the pane ends. Otherwise the pane's size.
final class PaneClip: NSView {
    let content: NSView
    let vertical: Bool
    var pinned: CGFloat? { didSet { needsLayout = true } }

    init(content: NSView, vertical: Bool) {
        self.content = content
        self.vertical = vertical
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Top-down, so a pane below a divider keeps its top edge on it.
    override var isFlipped: Bool { true }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pinned = pinned ?? 0
        content.frame = vertical
            ? NSRect(x: 0, y: 0, width: max(bounds.width, pinned), height: bounds.height)
            : NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, pinned))
    }
}

private extension NSSplitView {
    /// The split's length along its axis, and a pane's.
    var length: CGFloat { isVertical ? bounds.width : bounds.height }
    func length(of view: NSView) -> CGFloat { isVertical ? view.frame.width : view.frame.height }
}
