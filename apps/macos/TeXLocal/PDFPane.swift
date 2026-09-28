import CoreImage.CIFilterBuiltins
import PDFKit
import SwiftUI

/// The compiled PDF in PDFKit: native rendering, selection, zoom and find.
struct PDFPane: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var findQuery = ""
    @State private var finding = false
    /// Bumped to put the cursor in the find field, its text selected.
    @State private var findFocus = 0
    @AppStorage(PDFPrefs.paperKey) private var pdfPaper = PDFPrefs.paper
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = PDFController()
    /// The document read for a `pdfVersion`.
    @State private var loaded: (version: Int, document: PDFDocument)?

    var body: some View {
        PaneStack(finding: finding && project.pdfVersion > 0) {
            findBar
        } content: {
            pages
        }
        .toolbar(id: "pdf") { PDFToolbar(app: app, project: project, controller: controller) }
        .background { PDFColumn(collapsed: !project.showPDF, project: project) }
        // Edit › Find's items while the pages or the find bar have the keyboard.
        .focusedValue(\.find, findAction)
        .onChange(of: controller.page) { _, page in project.pdfPage = page }
        // A new PDF leaves every match behind; the web closes the bar too.
        .onChange(of: project.pdfVersion) { _, _ in
            if finding { closeFind() }
        }
        // Keyed on hasPDF too: the URL can arrive after the version.
        .task(id: project.hasPDF ? project.pdfVersion : 0) {
            let version = project.pdfVersion
            guard project.hasPDF, let url = project.pdfURL else { return }
            if let document = await Self.loadDocument(url) { loaded = (version, document) }
        }
        // A request made while the pane was off screen waits for it to appear; each is taken once.
        .onChange(of: app.pdfRequest?.token, initial: true) { _, _ in
            guard let action = app.pdfRequest?.action else { return }
            app.pdfRequest = nil
            // After this update, so a PDF view that has just appeared is in place.
            Task { perform(action) }
        }
    }

    /// Read whole: the next build rewrites the file in place.
    @concurrent nonisolated static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else { return nil }
        hideLinkBorders(document)
        return document
    }

    /// pdf.js (browser, Windows) leaves out hyperref's link boxes; the links still work.
    nonisolated private static func hideLinkBorders(_ document: PDFDocument) {
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == PDFMetrics.linkType {
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
            }
        }
    }

    private var darkPaper: Bool { pdfPaper == .dark || (pdfPaper == .auto && colorScheme == .dark) }

    @ViewBuilder
    private var pages: some View {
        if project.pdfVersion > 0 {
            PDFRepresentable(project: project, controller: controller, darkPaper: darkPaper,
                             document: loaded?.document, current: loaded?.version == project.pdfVersion)
                .overlay(alignment: .bottomTrailing) {
                    if controller.pageCount > 0 {
                        PageTile(controller: controller).padding()
                    }
                }
        } else {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// No PDF: TeX to install, a build that failed before making one, or
    /// nothing compiled yet.
    @ViewBuilder
    private var emptyState: some View {
        if !project.texAvailable {
            ContentUnavailableView {
                Label("TeX Isn’t Installed", systemImage: "doc.richtext")
            } description: {
                Text("Install MacTeX to compile. TeXLocal notices it once it’s there.")
            } actions: {
                GetMacTeXButton().buttonStyle(.borderedProminent)
            }
        } else if project.result?.failed == true {
            ContentUnavailableView {
                Label("Build Failed", systemImage: "xmark.octagon")
            } description: {
                Text("The build made no PDF. The build panel shows what went wrong.")
            } actions: {
                if !project.showLogs {
                    Button("Show Build Panel") { project.showBuildPanel() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Yet", systemImage: "doc.richtext")
            } description: {
                Text("Compile to preview your document.")
            } actions: {
                // Content, not a floating control: not glass.
                Button("Compile") { app.perform(.compileRun, on: project) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!app.isEnabled(.compileRun, on: project))
            }
        }
    }

    private func perform(_ action: PDFAction) {
        switch action {
        case .zoomIn: controller.zoom(in: true)
        case .zoomOut: controller.zoom(in: false)
        case .actualSize: controller.setScale(1)
        case .fitWidth: controller.fitWidth()
        case .fitHeight: controller.fitHeight()
        case .find: finding = true; findFocus += 1
        case .print: controller.view?.print(with: .shared, autoRotate: true)
        case .inverseFromView:
            if case let (page, point)? = controller.sourcePoint() {
                Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
            }
        }
    }

    /// Find in PDF: the source's find bar without its replace row.
    private var findBar: some View {
        FindBar(query: $findQuery, prompt: "Find in PDF", focus: findFocus,
                matches: FindMatches(index: controller.matchIndex + 1, total: controller.matches.count,
                                     limited: controller.limited),
                searched: controller.query, step: controller.step, close: closeFind)
            .task(id: findQuery) {
                try? await Task.sleep(for: PDFFind.debounce)
                if !Task.isCancelled, PDFFind.normalize(findQuery) != controller.query {
                    controller.find(findQuery)
                }
            }
    }

    /// What Edit › Find's items do in the PDF: no Replace.
    private func findAction(_ action: NSTextFinder.Action) -> (() -> Void)? {
        guard project.pdfVersion > 0 else { return nil }
        switch action {
        case .showFindInterface: return { perform(.find) }
        case .nextMatch, .previousMatch:
            guard !controller.matches.isEmpty else { return nil }
            return { controller.step(action == .nextMatch ? 1 : -1) }
        case .setSearchString:
            guard let text = controller.view?.currentSelection?.string, !text.isEmpty else { return nil }
            return {
                findQuery = text
                finding = true
            }
        default: return nil
        }
    }

    /// web/src/workspace.js `closePdfFind`: the bar goes, and its query and
    /// highlights with it.
    private func closeFind() {
        finding = false
        findQuery = ""
        controller.find("")
    }
}

/// The PDF's tools in the toolbar over it: viewing (zoom, Share), then the build
/// (the preview's state, settings, Compile), then Hide PDF at the trailing edge
/// (HIG, Toolbars).
struct PDFToolbar: CustomizableToolbarContent {
    let app: AppModel
    let project: ProjectModel
    let controller: PDFController

    // Declared whether the PDF shows or not: the system moves a collapsed column's
    // items to the source's section. Conditional items are safe only because the
    // PDF column never animates; a removed column item vanished mid-animation.
    var body: some CustomizableToolbarContent {
        if project.showPDF {
            ToolbarItem(id: "zoom") { zoomMenu }
                .visibilityPriority(.low)
        }
        ToolbarItem(id: "share") { shareControl }
            .visibilityPriority(.low)
        ToolbarSpacer(.flexible)
        if project.hasPDF, project.pdfFreshness != nil {
            ToolbarItem(id: "freshness") {
                FreshnessButton(project: project)
            }
            .customizationBehavior(.disabled)
        }
        ToolbarItem(id: "settings") {
            ProjectSettingsButton(project: project)
        }
        .customizationBehavior(.disabled)
        // Compile on glass of its own, not joined to its neighbours.
        ToolbarSpacer(.fixed)
        ToolbarItem(id: "compile") {
            CompileButton(project: project)
        }
        .customizationBehavior(.disabled)
        ToolbarSpacer(.fixed)
        ToolbarItem(id: "togglePDF") {
            PDFToggle(project: project)
        }
        .customizationBehavior(.disabled)
    }

    /// The scale, as a pull-down of zoom steps, fits and presets (View has the same
    /// commands with their shortcuts). While fitting, no preset is checked.
    private var zoomMenu: some View {
        Menu {
            Button("Zoom In") { controller.zoom(in: true) }
            Button("Zoom Out") { controller.zoom(in: false) }
            Divider()
            CheckedItem("Fit Width", checked: controller.fit == .width) { controller.fitWidth() }
            CheckedItem("Fit Height", checked: controller.fit == .height) { controller.fitHeight() }
            Divider()
            ForEach(Self.zoomPresets, id: \.self) { percent in
                CheckedItem((Double(percent) / 100).formatted(.percent),
                            checked: controller.fit == nil && Int((controller.scale * 100).rounded()) == percent) {
                    controller.setScale(CGFloat(percent) / 100)
                }
            }
        } label: {
            Text(controller.zoomLabel).monospacedDigit()
        }
        .help("Zoom")
        .accessibilityLabel("Zoom")
        .accessibilityValue(controller.zoomLabel)
        .disabled(project.pdfVersion == 0)
    }

    /// File › Share… opens its picker here too (`ProjectModel.sharePDF`).
    @ViewBuilder
    private var shareControl: some View {
        Group {
            if project.pdfVersion > 0, let url = project.pdfURL {
                ShareLink(item: url) { shareLabel }
            } else {
                Button {} label: { shareLabel }
                    .disabled(true)
            }
        }
        .help("Share PDF")
        .background { ShareAnchor(project: project) }
    }

    private var shareLabel: some View {
        Label("Share PDF", systemImage: "square.and.arrow.up")
    }

    private static let zoomPresets = [50, 75, 100, 125, 150, 200]
}

/// The toolbar's one prominent control; Stop in its place while a build runs.
/// Compile keeps its word: a lone play symbol reads as media.
struct CompileButton: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        if project.compiling {
            Button { project.stopCompile() } label: {
                // At least Compile's width, so the swap moves its neighbours less.
                ZStack {
                    label.hidden()
                    Label { Text("Stop") } icon: { ProgressView().controlSize(.small) }
                        .labelStyle(.titleAndIcon)
                }
            }
            // Glass, for Compile's padding.
            .buttonStyle(.glass)
            .fixedSize()
            .help("Stop")
        } else {
            Button { app.perform(.compileRun, on: project) } label: { label }
                .buttonStyle(.glassProminent)
                .fixedSize()
                .disabled(!app.isEnabled(.compileRun, on: project))
                .help("Compile")
        }
    }

    private var label: some View {
        Label("Compile", systemImage: "play.fill").labelStyle(.titleAndIcon)
    }
}

/// Collapses and opens the PDF column through its `NSSplitViewItem`: SwiftUI's split
/// can hide only its first column. The source's holding priority matches the PDF's so
/// the two share room the window gains or loses.
private struct PDFColumn: NSViewRepresentable {
    let collapsed: Bool
    let project: ProjectModel

    final class Coordinator {
        var lastCollapsed: Bool?
    }

    final class ColumnView: NSView {
        weak var project: ProjectModel?
        var collapsed = false
        private(set) var item: NSSplitViewItem?
        /// The source's share of its and the PDF's room as the PDF collapsed, given back
        /// in that proportion whatever the window's width by then.
        private var sourceShare: CGFloat?
        private var scheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            project?.window = window
            if window != nil { schedule() }
        }

        /// Whether the system's split has reset the source's holding priority.
        var priorityDrifted: Bool {
            guard let (split, index) = position else { return false }
            return split.splitViewItems[index - 1].holdingPriority != split.splitViewItems[index].holdingPriority
        }

        private var position: (NSSplitViewController, Int)? {
            guard let item, let split = item.viewController.parent as? NSSplitViewController,
                  let index = split.splitViewItems.firstIndex(of: item), index > 0 else { return nil }
            return (split, index)
        }

        /// Later: collapsing a split item inside a SwiftUI update hangs (27.2).
        func schedule() {
            guard !scheduled else { return }
            scheduled = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            scheduled = false
            guard window != nil else { return }
            if item == nil {
                item = splitViewItem
                guard let item else { return assertionFailure("PDF column's NSSplitViewItem not found") }
                item.canCollapse = true
            }
            guard let item, let (split, index) = position else { return }
            let sourceItem = split.splitViewItems[index - 1]
            sourceItem.holdingPriority = item.holdingPriority
            guard item.isCollapsed != collapsed else { return }
            let splitView = split.splitView
            let source = splitView.arrangedSubviews[index - 1]
            // At once, never animated: the toolbar's section line parts from a moving divider.
            if collapsed {
                let room = source.frame.width + item.viewController.view.frame.width
                if room > 0 { sourceShare = source.frame.width / room }
                item.isCollapsed = true
                return
            }
            let divider = sourceShare.map { share in
                source.frame.minX + ((source.frame.width - splitView.dividerThickness) * share).rounded()
            }
            item.isCollapsed = false
            guard let divider else { return }
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(divider, ofDividerAt: index - 1)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ColumnView {
        let view = ColumnView()
        view.project = project
        return view
    }

    func updateNSView(_ view: ColumnView, context: Context) {
        view.project = project
        view.collapsed = collapsed
        let coordinator = context.coordinator
        guard collapsed != coordinator.lastCollapsed || view.item == nil || view.priorityDrifted else { return }
        coordinator.lastCollapsed = collapsed
        view.schedule()
    }
}

/// Whether the preview is current: a failed build's warning, or the source edited
/// since. Choosing it shows the issues, or compiles.
private struct FreshnessButton: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        if let freshness = project.pdfFreshness {
            Button {
                if freshness == .edited { app.perform(.compileRun, on: project) } else { project.showBuildPanel() }
            } label: {
                Label {
                    Text(freshness.title)
                } icon: {
                    Image(systemName: freshness.systemImage)
                        .foregroundStyle(freshness == .lastSuccessful ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .help(freshness == .lastSuccessful
                  ? "The latest build failed; this is the last one that succeeded. Show Issues"
                  : "The preview doesn’t reflect the current source. Compile")
        }
    }
}

/// The PDF's own page numbers, not LaTeX's (front matter and roman numbers differ),
/// floating on glass over the pages.
private struct PageTile: View {
    let controller: PDFController

    var body: some View {
        Text("Page \(controller.page) of \(controller.pageCount)")
            .monospacedDigit()
            .padding(.horizontal)
            .frame(height: BarMetrics.largeControlHeight)
            .glassEffect(.regular, in: .capsule)
    }
}

/// The find bar's rules, shared with the web's (web/src/findsession.js and
/// workspace.js `showCount`, `pdfFindTimer`).
enum PDFFind {
    static let maxQuery = 256
    static let maxMatches = 5000
    /// So typing doesn't search every prefix.
    static let debounce: Duration = .milliseconds(200)

    static func normalize(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
    }
}

/// The PDF's paper; raw values shared with web/src/prefs.js.
enum PDFPaper: String, CaseIterable, Identifiable {
    case white, dark, auto

    var id: Self { self }

    var title: String {
        switch self {
        case .white: "White"
        case .dark: "Dark"
        case .auto: "Match Appearance"
        }
    }
}

/// The PDF's setting, shared by Settings and the pane.
enum PDFPrefs {
    static let paperKey = "pdfPaper"
    static let paper = PDFPaper.white
}

/// Named PDF view values.
private nonisolated enum PDFMetrics {
    /// "The text you are looking at": the first line at or below this fraction of the view.
    static let sourcePointFraction: CGFloat = 0.2
    /// How far down the page each look for that line steps.
    static let sourcePointStep: CGFloat = 6
    /// A neutral near-white that dark paper's inversion turns into dark mode's
    /// under-page grey: Core Image inverts in linear light.
    static let darkPaperBackground = NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)
    /// Matches .sync-flash in web/styles.css.
    static let flashDuration: Duration = .seconds(2.2)
    static let flashAlpha: CGFloat = 0.4
    /// PDFKit's `PDFAnnotation.type` is the subtype without its slash.
    static let linkType = String(PDFAnnotationSubtype.link.rawValue.dropFirst())
    /// Resizes from a SwiftUI column animation send no end signal; let go once they stop.
    static let resizeSettle: Duration = .milliseconds(300)
}

/// What the pane's controls and the menus ask of the PDF view.
@Observable
final class PDFController {
    @ObservationIgnored weak var view: SyncPDFView?
    var page = 0
    var pageCount = 0
    /// The query the matches are for, normalised.
    private(set) var query = ""
    var matches: [PDFSelection] = []
    var matchIndex = 0
    /// More matches exist than are kept.
    var limited = false
    /// Whether fitting or set.
    private(set) var scale: CGFloat = 1
    var zoomLabel: String { Double(scale).formatted(.percent.precision(.fractionLength(0))) }
    /// How the page is fitted to the view, or nil at a set scale.
    enum Fit { case width, height }
    private(set) var fit: Fit? = .width

    func pageChanged() {
        guard let view, let document = view.document, let page = view.currentPage else { return }
        self.page = document.index(for: page) + 1
        pageCount = document.pageCount
    }

    func scaleChanged() {
        guard let view else { return }
        scale = view.scaleFactor
        // Any other change of scale (a pinch, a zoom command) ends fitting.
        if view.autoScales {
            fit = .width
        } else if fit == .width || (fit == .height && abs(view.scaleFactor - heightScale(view)) > 0.001) {
            fit = nil
        }
    }

    private func heightScale(_ view: PDFView) -> CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        return view.bounds.height / page.bounds(for: view.displayBox).height
    }

    func setScale(_ scale: CGFloat) {
        guard let view else { return }
        fit = nil
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        guard let view else { return }
        fit = nil
        view.autoScales = false
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    /// In a continuous single-page layout, auto-scaling fits the page width.
    func fitWidth() {
        fit = .width
        view?.autoScales = true
        scaleChanged()
    }

    func fitHeight() {
        guard let view, view.currentPage != nil else { return }
        fit = .height
        view.autoScales = false
        view.scaleFactor = heightScale(view)
    }

    func find(_ value: String) {
        guard let view, let document = view.document else { return }
        query = PDFFind.normalize(value)
        let all = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        matches = Array(all.prefix(PDFFind.maxMatches))
        limited = all.count > matches.count
        matchIndex = 0
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        view.clearSelection()
        show()
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        show()
    }

    private func show() {
        guard let view, matches.indices.contains(matchIndex) else { return }
        view.setCurrentSelection(matches[matchIndex], animate: true)
        view.scrollSelectionToVisible(nil)
    }

    /// A SyncTeX point on a line of text: SyncTeX resolves only points on a glyph
    /// box, and the page centre is usually whitespace.
    func sourcePoint() -> (Int, CGPoint)? {
        guard let view, let document = view.document else { return nil }
        let probe = CGPoint(x: view.bounds.midX,
                            y: view.bounds.maxY - view.bounds.height * PDFMetrics.sourcePointFraction)
        guard let page = view.page(for: probe, nearest: true) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        var point = view.convert(probe, to: page)
        while point.y > bounds.minY {
            if let line = page.selectionForLine(at: point), let text = line.string,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let box = line.bounds(for: page)
                point = CGPoint(x: box.midX, y: box.minY)
                break
            }
            point.y -= PDFMetrics.sourcePointStep
        }
        return (document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: bounds))
    }
}

/// PDFView with a double-click that jumps to the source (inverse search).
final class SyncPDFView: PDFView {
    var onInverse: (Int, CGPoint) -> Void = { _, _ in }

    /// As the web draws it (`.pdf-dark`): inverted, then turned half way round the
    /// colour wheel so figures keep their hues. The view keeps the light appearance,
    /// whose background and scrollers the inversion turns dark.
    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            wantsLayer = true
            layerUsesCoreImageFilters = true
            appearance = darkPaper ? NSAppearance(named: .aqua) : nil
            // The tinted under-page colour would invert to olive.
            backgroundColor = darkPaper ? PDFMetrics.darkPaperBackground : .underPageBackgroundColor
            pageShadowsEnabled = !darkPaper
            let hue = CIFilter.hueAdjust()
            hue.angle = .pi
            contentFilters = darkPaper ? [CIFilter.colorInvert(), hue] : []
        }
    }

    /// The gap above page one, as a scroll inset rather than a page margin: fitting
    /// the width, PDFKit re-anchors page one to the view's top on every resize.
    var topInset: CGFloat = 0
    private var topInsetApplied = false

    /// PDFKit re-anchors page one on resize while fitting width; keep the top spot.
    private var anchor: (page: PDFPage, point: CGPoint)?
    private var anchorRelease: Task<Void, Never>?

    /// Where the pages start showing: under the top inset.
    private var topEdge: CGFloat {
        let inset = scrollView?.contentInsets.top ?? 0
        return isFlipped ? bounds.minY + inset : bounds.maxY - inset
    }

    private var scrollView: NSScrollView? { documentView?.enclosingScrollView }

    /// The scroll view exists once there's a document.
    func applyTopInset() {
        guard !topInsetApplied, let scrollView else { return }
        topInsetApplied = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
    }

    override func setFrameSize(_ size: NSSize) {
        if anchor == nil, size != frame.size, frame.size != .zero,
           let page = page(for: CGPoint(x: bounds.midX, y: topEdge), nearest: true) {
            anchor = (page, convert(CGPoint(x: bounds.midX, y: topEdge), to: page))
        }
        super.setFrameSize(size)
    }

    override func layout() {
        super.layout()
        guard anchor != nil else { return }
        // PDFKit sets its fitted scale after the layout that resized it.
        restoreAnchor()
        anchorRelease?.cancel()
        anchorRelease = Task { [weak self] in
            try? await Task.sleep(for: PDFMetrics.resizeSettle)
            guard !Task.isCancelled else { return }
            self?.releaseAnchor()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if anchor != nil { releaseAnchor() }
    }

    private func releaseAnchor() {
        anchorRelease?.cancel()
        anchorRelease = nil
        restoreAnchor()
        anchor = nil
    }

    private func restoreAnchor() {
        guard let (page, point) = anchor, let clip = scrollView?.contentView else { return }
        layoutDocumentView()
        let drift = convert(point, from: page).y - topEdge
        // The clip view scrolls the other way when one of the two is flipped.
        var origin = clip.bounds.origin
        origin.y += isFlipped == clip.isFlipped ? drift : -drift
        clip.scroll(to: origin)
        scrollView?.reflectScrolledClipView(clip)
    }

    /// Page one's top at the top of what shows, at the next layout: a new document
    /// is shown at the scroll view's edge, over the inset.
    func scrollToTop() {
        guard let page = document?.page(at: 0) else { return }
        anchor = (page, CGPoint(x: 0, y: page.bounds(for: displayBox).maxY))
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let document else {
            super.mouseDown(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: true) else { return }
        let point = convert(location, to: page)
        let synctex = SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox))
        onInverse(document.index(for: page) + 1, synctex)
    }
}

private struct PDFRepresentable: NSViewRepresentable {
    let project: ProjectModel
    let controller: PDFController
    let darkPaper: Bool
    let document: PDFDocument?
    /// Whether `document` is the current build's.
    let current: Bool

    final class Coordinator {
        var highlightToken = 0
        /// Following the view's page and scale, until the view goes.
        var watches: [Task<Void, Never>] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // An even margin round every page, lined up with the bars' controls.
        let inset = BarMetrics.inset
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: inset, bottom: inset, right: inset)
        view.topInset = inset
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.onInverse = { [project] page, point in
            Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
        }
        controller.view = view
        let center = NotificationCenter.default
        // Each read once as it starts watching too: the first fitted scale is set before.
        context.coordinator.watches = [
            Task { [controller] in
                let changes = center.notifications(named: .PDFViewPageChanged, object: view)
                controller.pageChanged()
                for await _ in changes { controller.pageChanged() }
            },
            Task { [controller] in
                let changes = center.notifications(named: .PDFViewScaleChanged, object: view)
                controller.scaleChanged()
                for await _ in changes { controller.scaleChanged() }
            },
        ]
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        view.darkPaper = darkPaper
        if let document, view.document !== document { show(document, in: view) }
        // Only on the current build's pages: the jump would be lost to the swap.
        if current, let highlight = project.highlight, highlight.token != context.coordinator.highlightToken {
            context.coordinator.highlightToken = highlight.token
            flash(highlight.loc, in: view)
        }
    }

    static func dismantleNSView(_ view: SyncPDFView, coordinator: Coordinator) {
        coordinator.watches.forEach { $0.cancel() }
    }

    /// A rebuilt PDF at the same scroll offset and zoom: the same spot, pages keeping
    /// their size. Not `currentDestination`: it ignores the top inset.
    private func show(_ document: PDFDocument, in view: SyncPDFView) {
        let clip = view.documentView?.enclosingScrollView?.contentView
        let offset = view.document == nil ? nil : clip?.bounds.origin
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        view.applyTopInset()
        if !autoScales { view.scaleFactor = scale }
        // A reopened project's first PDF opens at the page it was left at.
        let restore = project.restorePDFPage.map { min(max($0, 1), document.pageCount) - 1 }
        project.restorePDFPage = nil
        if let clip, let offset {
            view.layoutDocumentView()
            clip.scroll(to: offset)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        } else if let restore, restore > 0, let page = document.page(at: restore) {
            view.go(to: page)
        } else {
            view.scrollToTop()
        }
        controller.pageCount = document.pageCount
        controller.pageChanged()
        controller.scaleChanged()
    }

    /// Scroll to a forward-search result and flash it.
    private func flash(_ loc: ForwardLoc, in view: SyncPDFView) {
        guard let page = view.document?.page(at: Int(loc.page) - 1) else { return }
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        let mark = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(PDFMetrics.flashAlpha)
        page.addAnnotation(mark)
        view.go(to: rect.insetBy(dx: 0, dy: -view.bounds.height / 3), on: page)
        Task {
            try? await Task.sleep(for: PDFMetrics.flashDuration)
            page.removeAnnotation(mark)
        }
    }
}

/// Where File › Share… opens its picker. AppKit: SwiftUI opens a share picker only
/// from a `ShareLink` itself, never from a menu item.
private struct ShareAnchor: NSViewRepresentable {
    let project: ProjectModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        project.shareAnchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        project.shareAnchor = view
    }
}

extension ProjectModel {
    /// File › Share…: the share picker under the toolbar's Share button while it
    /// shows, else under the toolbar, centred.
    func sharePDF() {
        guard pdfVersion > 0, let url = pdfURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let anchor = shareAnchor, anchor.window?.isVisible == true, !anchor.isHiddenOrHasHiddenAncestor,
           !anchor.visibleRect.isEmpty {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        } else if let content = window?.contentView {
            let area = content.safeAreaRect
            let top = NSRect(x: area.midX, y: content.isFlipped ? area.minY : area.maxY - 1, width: 1, height: 1)
            picker.show(relativeTo: top, of: content, preferredEdge: content.isFlipped ? .maxY : .minY)
        }
    }
}
