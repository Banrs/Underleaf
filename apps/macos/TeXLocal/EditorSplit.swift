import AppKit
import SwiftUI

/// Source | PDF over the build panel. AppKit's split, for what SwiftUI's lack: a pane hidden
/// and shown through an animated collapse, and dividers kept across launches (`autosaveName`).
struct EditorSplit: NSViewControllerRepresentable {
    let app: AppModel
    let project: ProjectModel
    let showPDF: Bool
    let showPanel: Bool

    func makeNSViewController(context: Context) -> EditorSplitController {
        EditorSplitController(app: app, project: project)
    }

    func updateNSViewController(_ split: EditorSplitController, context: Context) {
        split.show(pdf: showPDF, panel: showPanel, animated: !context.environment.accessibilityReduceMotion)
    }
}

final class EditorSplitController: NSSplitViewController {
    /// Source and PDF each, about 40 columns of the editor's text; and the build panel, its
    /// header and a few rows.
    private static let paneMinimum: CGFloat = 300
    private static let panelMinimum: CGFloat = 120

    private let columns = NSSplitViewController()
    private let sourceItem: NSSplitViewItem
    private let pdfItem: NSSplitViewItem
    private let panelItem: NSSplitViewItem
    private let pdf: PDFController
    /// What the window shows, applied once the panes have loaded (`viewDidLoad`).
    private var shown = (pdf: true, panel: false)
    /// The panel's height as it was hidden, which AppKit doesn't keep.
    private var panelHeight: CGFloat = 0
    private var animations = 0
    private var frames: CADisplayLink?

    init(app: AppModel, project: ProjectModel) {
        pdf = project.pdf
        // Equal widths, the source and PDF in halves; the panel a quarter of the height. An
        // autosave from an earlier launch wins.
        sourceItem = NSSplitViewItem(viewController: Self.host(SourceColumn(project: project), app, CGSize(width: 1, height: 3)))
        pdfItem = NSSplitViewItem(viewController: Self.host(PDFPane(project: project), app, CGSize(width: 1, height: 3)))
        panelItem = NSSplitViewItem(viewController: Self.host(BuildPanel(project: project), app, CGSize(width: 2, height: 1)))
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.autosaveName = "Area"
        columns.splitView.isVertical = true
        columns.splitView.dividerStyle = .thin
        columns.splitView.autosaveName = "Columns"
        sourceItem.minimumThickness = Self.paneMinimum
        pdfItem.minimumThickness = Self.paneMinimum
        // Hidden by its toggle only, and then the source takes its room, not the window.
        pdfItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        let columnsItem = NSSplitViewItem(viewController: columns)
        columnsItem.minimumThickness = Self.paneMinimum * 2 / 3
        panelItem.minimumThickness = Self.panelMinimum
        // It keeps its height as the window resizes; the editors take the change.
        panelItem.holdingPriority = .defaultLow + 1
        panelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        addSplitViewItem(columnsItem)
        addSplitViewItem(panelItem)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A pane: SwiftUI whose sizes stay out of Auto Layout, so the split item's limits size it.
    private static func host(_ content: some View, _ app: AppModel, _ size: CGSize) -> NSViewController {
        let host = NSHostingController(rootView: content.environment(app))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: size.width * 500, height: size.height * 200)
        return host
    }

    /// The autosaves restore which panes were collapsed as the splits load; the window's
    /// choice wins.
    override func viewDidLoad() {
        super.viewDidLoad()
        _ = columns.view
        show(pdf: shown.pdf, panel: shown.panel, animated: false)
    }

    func show(pdf: Bool, panel: Bool, animated: Bool) {
        shown = (pdf, panel)
        guard isViewLoaded else { return }
        setCollapsed(pdfItem, !pdf, animated: animated)
        setCollapsed(panelItem, !panel, animated: animated)
    }

    /// Through AppKit's collapse animation, which brings a pane back at the size it was
    /// hidden at; at once off screen or with Reduce Motion.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, animated: Bool) {
        // Repeated updates must not snap an animation already heading there.
        guard item.isCollapsed != collapsed else {
            if item === pdfItem, collapsed { pdf.columnShown = false }
            return
        }
        let panel = item === panelItem, split = splitView
        if item === pdfItem, collapsed { pdf.columnShown = false }
        if panel {
            // AppKit brings the panel back at its hosted view's height.
            if collapsed { panelHeight = item.viewController.view.frame.height }
            else if panelHeight > 0 { item.viewController.view.frame.size.height = panelHeight }
        }
        // The PDF's actions wait for its column's width (`PDFController.whenShown`).
        let settled: @MainActor @Sendable () -> Void = { [pdf, pdfItem] in
            if item === pdfItem, !pdfItem.isCollapsed { pdf.columnShown = true }
        }
        guard animated, view.window?.isVisible == true else {
            item.isCollapsed = collapsed
            if panel, !collapsed, panelHeight > 0 {
                split.setPosition(split.bounds.height - split.dividerThickness - panelHeight, ofDividerAt: 0)
            }
            settled()
            return
        }
        animating(true)
        NSAnimationContext.runAnimationGroup { _ in
            item.animator().isCollapsed = collapsed
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.animating(false)
                settled()
            }
        }
    }

    /// AppKit's collapse animation doesn't always reach the screen: with nothing else waking
    /// the run loop, a pane holds still, then jumps to its end (27.2). Laid out on every
    /// frame meanwhile, the panes keep up with it.
    private func animating(_ running: Bool) {
        animations += running ? 1 : -1
        if running, frames == nil {
            frames = view.displayLink(target: self, selector: #selector(frame))
            frames?.add(to: .main, forMode: .common)
        } else if animations == 0 {
            frames?.invalidate()
            frames = nil
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        splitView.needsLayout = true
        columns.splitView.needsLayout = true
    }
}
