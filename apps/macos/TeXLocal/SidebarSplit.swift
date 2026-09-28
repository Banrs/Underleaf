import AppKit
import SwiftUI

/// A pane of the sidebar's `SidebarSplit`: its sizes, and whether it's shown
/// or folded. The split holds its view.
struct SidebarPane {
    var minimum: CGFloat = 0
    /// The share it opens at when it has no stored size.
    var fraction: CGFloat?
    /// Keeps its height as the window resizes; the others share the rest.
    var keepsSize = false
    var shown = true
    /// Folded to this height (its header), its divider fixed; unfolding goes
    /// back to its stored size.
    var collapsed: CGFloat?
    /// Told when a fold or unfold has finished: whether it's folded.
    var didFold: ((Bool) -> Void)?
}

/// The sidebar's split, Files over the File Outline.
/// Plain NSSplitView: inside NSSplitViewController items SwiftUI sidebar lists start 10 pt low (27.2).
struct SidebarSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let app: AppModel
    let autosave: String
    let top: SidebarPane
    let bottom: SidebarPane
    @ViewBuilder let topContent: Top
    @ViewBuilder let bottomContent: Bottom

    private var panes: [SidebarPane] { [top, bottom] }

    func makeCoordinator() -> SidebarSplitCoordinator { SidebarSplitCoordinator(autosave: autosave) }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        context.coordinator.panes = panes
        // Made once: the views observe the models themselves.
        let hosts = [host(topContent), host(bottomContent)]
        let stored = PaneSizes.load(autosave)
        let shown = panes.indices.filter { panes[$0].shown }
        // Stored sizes only when every shown pane has one: they're absolute, the
        // shares are proportions of the scale below.
        let useStored = shown.allSatisfy { stored[$0] != nil || panes[$0].collapsed != nil }
        let rest = 1 - panes.compactMap(\.fraction).reduce(0, +)
        // Any length: the first resize scales the sharing panes to the split.
        let scale: CGFloat = 1000
        for (index, (pane, host)) in zip(panes, hosts).enumerated() {
            let view = PaneClip(content: host)
            context.coordinator.clips.append(view)
            let height = pane.collapsed
                ?? (useStored ? stored[index] : nil)
                ?? (pane.fraction ?? rest) * scale
            view.frame.size = CGSize(width: scale, height: height)
            if pane.shown { split.addArrangedSubview(view) }
        }
        return split
    }

    private func host(_ content: some View) -> NSView {
        let host = NSHostingView(rootView: content.environment(app))
        // SwiftUI's sizes stay out of Auto Layout; the delegate bounds each pane.
        host.sizingOptions = []
        return host
    }

    /// Shows, hides, folds and unfolds panes. A hidden pane leaves the split,
    /// since AppKit keeps room for a merely hidden subview.
    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        let was = coordinator.panes
        coordinator.panes = panes
        for (index, (view, pane)) in zip(coordinator.clips, panes).enumerated()
        where was[index].collapsed != pane.collapsed {
            if pane.shown, view.superview === split {
                coordinator.fold(split, index, to: pane.collapsed, keeping: was[index].collapsed == nil) {
                    pane.didFold?(pane.collapsed != nil)
                }
            } else {
                // Out of the split, nothing slides: it comes back as it now is.
                pane.didFold?(pane.collapsed != nil)
            }
        }
        for (index, (view, pane)) in zip(coordinator.clips, panes).enumerated() {
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
                    place = coordinator.clips[..<index].filter { $0.superview === split }.count
                    split.insertArrangedSubview(view, at: place)
                    split.adjustSubviews()
                    // It opens from nothing.
                    if place > 0 { coordinator.slide(split, divider: place - 1, to: closed, animated: false) }
                }
                if place > 0 {
                    let size = pane.collapsed
                        ?? coordinator.hidden[index].map { pane.keepsSize ? $0 : $0 * total }
                        ?? coordinator.openingSize(index, in: total)
                    // Laid out at the size it opens to, and slid in whole.
                    view.pinned = size
                    coordinator.slide(split, divider: place - 1, to: total - size - split.dividerThickness) {
                        view.pinned = nil
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
                view.pinned = split.length(of: view)
                coordinator.slide(split, divider: place - 1, to: closed) {
                    view.pinned = nil
                    // Shown again while it closed: it stays.
                    guard coordinator.hiding.remove(index) != nil else { return }
                    remove()
                }
            }
        }
    }
}

/// The sidebar split's delegate: keeps dragged dividers within both panes'
/// limits, and on a window resize gives each pane its share as last set
/// rather than what the last resize left, so a squeezed pane recovers.
final class SidebarSplitCoordinator: NSObject, NSSplitViewDelegate, NSAnimationDelegate {
    /// The start share of a pane with none of its own.
    private static let defaultFraction: CGFloat = 0.5

    let autosave: String
    var panes: [SidebarPane] = []
    /// Each pane, by index.
    var clips: [PaneClip] = []
    /// Hidden panes' shares of the split (sizes for a pane that keeps its size).
    var hidden: [Int: CGFloat] = [:]
    /// The shown panes' sizes as last set, by index.
    private var wanted: [Int: CGFloat] = [:]
    /// The sizes the last resize gave the panes: any others were set since.
    private var laidOut: [CGFloat] = []

    /// Panes sliding shut, by index: still in the split until closed.
    var hiding: Set<Int> = []
    /// A divider moving: the limits stand aside until it arrives.
    private var sliding: (animation: NSAnimation, finish: () -> Void)?
    /// A divider set where a slide ends, at once: the limits stand aside so a
    /// pane opens from nothing, not its minimum.
    private var placing = false
    private var free: Bool { sliding != nil || placing }

    init(autosave: String) {
        self.autosave = autosave
    }

    /// Moves a divider to `position`, at once off screen or with Reduce
    /// Motion, then runs `done`. A slide under way arrives first.
    func slide(_ split: NSSplitView, divider: Int, to position: CGFloat, animated: Bool = true,
               done: @escaping () -> Void = {}) {
        sliding?.animation.stop()
        sliding?.finish()
        let from = span(split, divider).upper
        let finish = { [weak self, weak split] in
            guard let self else { return }
            self.sliding = nil
            self.placing = true
            split?.setPosition(position, ofDividerAt: divider)
            self.placing = false
            done()
            // A placement without animation is a first step, not a size to keep.
            if animated, let split { self.takeSizes(split) }
        }
        guard animated, abs(position - from) > 1, split.window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
        let animation = DividerSlide(duration: NSAnimationContext.current.duration) { [weak split] value in
            split?.setPosition(from + (position - from) * value, ofDividerAt: divider)
        }
        animation.delegate = self
        sliding = (animation, finish)
        animation.start()
    }

    func animationDidEnd(_ animation: NSAnimation) {
        guard animation === sliding?.animation else { return }
        sliding?.finish()
    }

    /// Where a pane opens with no size from this session: its stored size, or its share.
    func openingSize(_ index: Int, in total: CGFloat) -> CGFloat {
        let pane = panes[index]
        if let stored = PaneSizes.load(autosave)[index], stored > minimum(pane) { return stored }
        return (pane.fraction ?? Self.defaultFraction) * total
    }

    /// Folds a pane to `size`, first storing the size it had (`keeping`: it
    /// was unfolded), or (`size` nil) unfolds it to its stored size, then runs
    /// `done`. Only a pane after the first: it moves the divider before it.
    func fold(_ split: NSSplitView, _ index: Int, to size: CGFloat?, keeping: Bool = true,
              done: @escaping () -> Void = {}) {
        let view = clips[index]
        guard let place = split.arrangedSubviews.firstIndex(of: view), place > 0 else { return }
        let end = span(split, place).upper
        let target: CGFloat
        if let size {
            if keeping { PaneSizes.save([index: split.length(of: view)], autosave) }
            target = size
        } else {
            target = openingSize(index, in: split.length)
        }
        slide(split, divider: place - 1, to: end - target - split.dividerThickness) { [weak split] in
            split?.adjustSubviews()
            done()
        }
    }

    /// The pane shown at a place in the split.
    private func pane(_ split: NSSplitView, _ place: Int) -> SidebarPane {
        panes[clips.firstIndex { $0 === split.arrangedSubviews[place] } ?? place]
    }

    private func index(of view: NSView) -> Int? { clips.firstIndex { $0 === view } }

    /// The most a pane may take: its folded size while folded.
    private func maximum(_ pane: SidebarPane) -> CGFloat { pane.collapsed ?? .infinity }

    /// The least a pane may take: its folded size while folded.
    private func minimum(_ pane: SidebarPane) -> CGFloat { pane.collapsed ?? pane.minimum }

    /// Where the pane at a place starts and ends, top down (the split is flipped).
    private func span(_ split: NSSplitView, _ place: Int) -> (lower: CGFloat, upper: CGFloat) {
        let frame = split.arrangedSubviews[place].frame
        return (frame.minY, frame.maxY)
    }

    /// Takes sizes set since the last resize (a drag, a pane shown or hidden)
    /// as the ones to keep, and stores the shown, unfolded panes'.
    private func takeSizes(_ split: NSSplitView) {
        let current = split.arrangedSubviews.map(split.length(of:))
        guard current.count != laidOut.count || zip(current, laidOut).contains(where: { abs($0 - $1) > 0.5 })
        else { return }
        // The first layout's sizes are the start scale, not sizes to store.
        let first = laidOut.isEmpty
        wanted = [:]
        for (view, size) in zip(split.arrangedSubviews, current) {
            if let index = index(of: view) { wanted[index] = size }
        }
        laidOut = current
        guard !first, !free, split.length > 0 else { return }
        PaneSizes.save(wanted.filter { index, size in
            panes[index].collapsed == nil && !hiding.contains(index) && size >= panes[index].minimum
        }, autosave)
    }

    /// What a pane being hidden comes back to: its share as last set, not what
    /// a small window squeezed it to; a pane that keeps its size, that size.
    func share(_ split: NSSplitView, of index: Int) -> CGFloat? {
        takeSizes(split)
        guard let size = wanted[index] else { return nil }
        return panes[index].keepsSize ? size : size / max(wanted.values.reduce(0, +), 1)
    }

    /// A dragged divider: stored as it's set.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !free, hiding.isEmpty, let split = notification.object as? NSSplitView else { return }
        takeSizes(split)
    }

    func splitView(_ split: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        takeSizes(split)
        let shown = split.arrangedSubviews
        let places = shown.indices
        let room = split.length - split.dividerThickness * CGFloat(max(shown.count - 1, 0))
        let limits = places.map { place in
            let pane = pane(split, place)
            // A pane sliding open or shut passes under its minimum.
            return (low: free ? 0 : minimum(pane), high: maximum(pane), keeps: pane.keepsSize || pane.collapsed != nil)
        }
        let want = places.map { place in
            index(of: shown[place]).flatMap { wanted[$0] } ?? split.length(of: shown[place])
        }
        // Panes that keep their size have it; the rest share what is left.
        let kept = places.filter { limits[$0].keeps }.map { want[$0] }.reduce(0, +)
        let shared = places.filter { !limits[$0].keeps }.map { want[$0] }.reduce(0, +)
        var sizes = places.map { place in
            limits[place].keeps ? want[place] : want[place] / max(shared, 1) * max(room - kept, 0)
        }
        // Clamped to each pane's limits; the difference settled by the sharing
        // panes first, then the ones that keep their size.
        for place in places { sizes[place] = min(max(sizes[place], limits[place].low), limits[place].high) }
        var excess = sizes.reduce(0, +) - room
        for keeps in [false, true] {
            for place in places.reversed() where limits[place].keeps == keeps && excess != 0 {
                let change = excess > 0
                    ? min(excess, sizes[place] - limits[place].low)
                    : max(excess, sizes[place] - limits[place].high)
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
            shown[place].frame = NSRect(x: 0, y: offset, width: split.bounds.width, height: size)
            offset += size + split.dividerThickness
        }
        laidOut = shown.map(split.length(of:))
    }

    /// A pane that keeps its size leaves a window resize to the others.
    func splitView(_ split: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard let index = index(of: view) else { return true }
        return !panes[index].keepsSize && panes[index].collapsed == nil
    }

    /// A folded pane's divider doesn't drag, and shows no resize pointer.
    func splitView(_ split: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect,
                   ofDividerAt place: Int) -> NSRect {
        let beside = [place, place + 1].filter(split.arrangedSubviews.indices.contains)
        return free || beside.contains { pane(split, $0).collapsed != nil } ? .zero : proposed
    }

    // A divider's position is where the pane above it ends.
    func splitView(_ split: NSSplitView, constrainMinCoordinate proposed: CGFloat,
                   ofSubviewAt place: Int) -> CGFloat {
        if free { return proposed }
        let low = max(span(split, place).lower + minimum(pane(split, place)),
                      span(split, place + 1).upper - maximum(pane(split, place + 1)) - split.dividerThickness)
        return max(proposed, low)
    }

    func splitView(_ split: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
                   ofSubviewAt place: Int) -> CGFloat {
        if free { return proposed }
        let high = min(span(split, place + 1).upper - minimum(pane(split, place + 1)) - split.dividerThickness,
                       span(split, place).lower + maximum(pane(split, place)))
        return min(proposed, high)
    }
}

/// A divider's slide, eased.
/// NSAnimation runs on the run loop; the split's displayLink stops while the screen is locked.
private nonisolated final class DividerSlide: NSAnimation {
    private let step: @MainActor @Sendable (CGFloat) -> Void

    init(duration: TimeInterval, step: @escaping @MainActor @Sendable (CGFloat) -> Void) {
        self.step = step
        super.init(duration: duration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
    }

    required init?(coder: NSCoder) { fatalError() }

    // A nonblocking animation steps on the main run loop.
    override var currentProgress: NSAnimation.Progress {
        didSet {
            let value = CGFloat(currentValue), step = step
            MainActor.assumeIsolated { step(value) }
        }
    }
}

/// A pane's content, laid out at `pinned` height while the pane slides, so it
/// moves whole instead of rewrapping at every height; clipped to the pane.
final class PaneClip: NSView {
    let content: NSView
    var pinned: CGFloat? { didSet { needsLayout = true } }

    init(content: NSView) {
        self.content = content
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
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, pinned ?? 0))
    }
}
