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

    static func load(_ autosave: String) -> [Int: CGFloat] {
        let stored = UserDefaults.standard.dictionary(forKey: key(autosave)) as? [String: Double] ?? [:]
        return stored.reduce(into: [:]) { sizes, entry in
            if let index = Int(entry.key), entry.value > 0 { sizes[index] = entry.value }
        }
    }

    /// Merges into what is stored, so panes left out keep their entries.
    static func save(_ sizes: [Int: CGFloat], _ autosave: String) {
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
