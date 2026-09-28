import SwiftUI

/// A pane of a `SplitController`: an `NSSplitViewItem` holding a SwiftUI view.
struct SplitPane {
    var minimum: CGFloat?
    /// At most this share of the split, so a pane that keeps its size gives
    /// way in a small window.
    var maxFraction: CGFloat?
    /// The share it opens at when it has no stored size.
    var fraction: CGFloat?
    /// Holds its size above the others' holding priority as the window resizes.
    var keepsSize = false
    var shown = true
    /// Type-erased once, at the hosting boundary; each pane's type never changes.
    let content: AnyView

    init(minimum: CGFloat? = nil, maxFraction: CGFloat? = nil, fraction: CGFloat? = nil,
         keepsSize: Bool = false, shown: Bool = true, @ViewBuilder content: () -> some View) {
        self.minimum = minimum
        self.maxFraction = maxFraction
        self.fraction = fraction
        self.keepsSize = keepsSize
        self.shown = shown
        self.content = AnyView(content())
    }
}

/// The app-owned record of a split's pane sizes, by pane index. AppKit's
/// autosave stores only the panes in the split, so a hidden pane lost its size.
enum PaneSizes {
    static func key(_ autosave: String) -> String { "\(autosave) Pane Sizes" }

    fileprivate static func load(_ autosave: String) -> [Int: CGFloat] {
        let stored = UserDefaults.standard.dictionary(forKey: key(autosave)) as? [String: Double] ?? [:]
        return stored.reduce(into: [:]) { sizes, entry in
            if let index = Int(entry.key), entry.value > 0 { sizes[index] = entry.value }
        }
    }

    /// Merges into what is stored, so panes left out keep their entries.
    fileprivate static func save(_ sizes: [Int: CGFloat], _ autosave: String) {
        guard !sizes.isEmpty else { return }
        var stored = UserDefaults.standard.dictionary(forKey: key(autosave)) as? [String: Double] ?? [:]
        for (index, size) in sizes { stored[String(index)] = Double(size.rounded()) }
        UserDefaults.standard.set(stored, forKey: key(autosave))
    }
}

/// A split of SwiftUI panes on `NSSplitViewController`, for the build panel
/// under the source. SwiftUI's VSplitView laid panes out past their bounds
/// and pinned the window's width (27.2).
struct SplitController: NSViewControllerRepresentable {
    let app: AppModel
    let axis: Axis
    let autosave: String
    let panes: [SplitPane]

    func makeNSViewController(context: Context) -> PaneSplitViewController {
        PaneSplitViewController(app: app, vertical: axis == .horizontal, autosave: autosave, panes: panes)
    }

    func updateNSViewController(_ controller: PaneSplitViewController, context: Context) {
        controller.update(panes)
    }

    /// The whole proposal: the items' minimums constrain the split's view and
    /// must not reach the window's layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: PaneSplitViewController,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// A `SplitController`'s split view controller: an item per pane.
final class PaneSplitViewController: NSSplitViewController {
    private let app: AppModel
    private let vertical: Bool
    private let autosave: String
    private var panes: [SplitPane]
    /// Panes that have their size this session; any other opens at its stored
    /// size or share, since the split alone opens it at its minimum.
    private var sized: Set<Int>
    private let saved: [Int: CGFloat]
    /// Each item's own thickness limits, restored after a hold.
    private var limits: [(minimum: CGFloat, maximum: CGFloat)] = []
    private var caps: [Int: NSLayoutConstraint] = [:]
    /// Shows and hides under way: their passing sizes aren't stored.
    private var animating = 0
    private var resizeObserver: NotificationCenter.ObservationToken?

    init(app: AppModel, vertical: Bool, autosave: String, panes: [SplitPane]) {
        self.app = app
        self.vertical = vertical
        self.autosave = autosave
        self.panes = panes
        saved = PaneSizes.load(autosave)
        // A pane with no share takes what the others leave.
        sized = Set(panes.indices.filter { panes[$0].fraction == nil })
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = vertical
        for pane in panes {
            let host = NSHostingController(rootView: pane.content.environment(app))
            // SwiftUI's sizes stay out of Auto Layout; the item's limits bound the pane.
            host.sizingOptions = []
            let item = NSSplitViewItem(viewController: host)
            if let minimum = pane.minimum { item.minimumThickness = minimum }
            if pane.keepsSize { item.holdingPriority = .defaultLow + 1 }
            // Shown and hidden by the app only, not by dragging its divider.
            item.canCollapse = false
            // Collapsed before it's added: its view loads when first shown.
            item.isCollapsed = !pane.shown
            addSplitViewItem(item)
            limits.append((item.minimumThickness, item.maximumThickness))
        }
        for (index, pane) in panes.enumerated() where pane.maxFraction != nil {
            cap(index)
        }
        resizeObserver = NotificationCenter.default.addObserver(of: splitView, for: .didResizeSubviews) {
            [weak self] _ in self?.storeSizes()
        }
    }

    isolated deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    /// Stores each placed, shown pane's length; hidden panes keep their entries.
    private func storeSizes() {
        guard animating == 0, view.window != nil, splitView.length > 0 else { return }
        var sizes: [Int: CGFloat] = [:]
        for (index, item) in splitViewItems.enumerated() where !item.isCollapsed && sized.contains(index) {
            sizes[index] = splitView.length(of: item.viewController.view)
        }
        PaneSizes.save(sizes, autosave)
    }

    /// A pane at most its share of the split, giving way only to the split's
    /// own constraints.
    private func cap(_ index: Int) {
        guard let fraction = panes[index].maxFraction, caps[index] == nil,
              !splitViewItems[index].isCollapsed else { return }
        let view = splitViewItems[index].viewController.view
        let constraint = vertical
            ? view.widthAnchor.constraint(lessThanOrEqualTo: splitView.widthAnchor, multiplier: fraction)
            : view.heightAnchor.constraint(lessThanOrEqualTo: splitView.heightAnchor, multiplier: fraction)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        caps[index] = constraint
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        placeOpeningPanes()
    }

    /// The sizes the shown panes open at, once the split has its length.
    private func placeOpeningPanes() {
        let opening = panes.indices.filter { !sized.contains($0) && !splitViewItems[$0].isCollapsed }
        guard !opening.isEmpty, splitView.length > 0 else { return }
        for index in opening { hold(index, at: openingSize(index)) }
        splitView.layoutSubtreeIfNeeded()
        // Dividers set where the held sizes put them, so the split keeps the
        // sizes once they're freed.
        for index in opening where index > 0 {
            let before = splitView.arrangedSubviews[index - 1].frame
            splitView.setPosition(splitView.isVertical ? before.maxX : before.maxY, ofDividerAt: index - 1)
        }
        for index in opening { free(index) }
        storeSizes()
    }

    /// Deferred past SwiftUI's update: a collapse lays the window out at once,
    /// re-enters the update and hangs in an AttributeGraph cycle (27.2).
    func update(_ new: [SplitPane]) {
        panes = new
        guard isViewLoaded else { return }
        Task { [weak self] in self?.applyShown() }
    }

    private func applyShown() {
        for (index, (item, pane)) in zip(splitViewItems, panes).enumerated() where item.isCollapsed == pane.shown {
            let opening = pane.shown && !sized.contains(index)
            if opening { hold(index, at: openingSize(index)) }
            animating += 1
            NSAnimationContext.runAnimationGroup { _ in
                item.animator().isCollapsed = !pane.shown
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if opening { self.free(index) }
                    self.animating -= 1
                    self.storeSizes()
                }
            }
            if pane.shown { cap(index) }
        }
    }

    /// Its stored size, or its share, within its most.
    private func openingSize(_ index: Int) -> CGFloat? {
        let pane = panes[index]
        guard let size = saved[index] ?? pane.fraction.map({ $0 * splitView.length }) else { return nil }
        return pane.maxFraction.map { min(size, $0 * splitView.length) } ?? size
    }

    /// Holds a pane at one size until `free`.
    private func hold(_ index: Int, at size: CGFloat?) {
        // Whole points: a pane half a point off centred its content half a point low.
        guard let size = size?.rounded() else { return }
        splitViewItems[index].minimumThickness = size
        splitViewItems[index].maximumThickness = size
    }

    private func free(_ index: Int) {
        sized.insert(index)
        splitViewItems[index].minimumThickness = limits[index].minimum
        splitViewItems[index].maximumThickness = limits[index].maximum
    }
}

extension NSSplitView {
    /// The split's length along its axis, and a pane's.
    var length: CGFloat { isVertical ? bounds.width : bounds.height }
    func length(of view: NSView) -> CGFloat { isVertical ? view.frame.width : view.frame.height }
}

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
