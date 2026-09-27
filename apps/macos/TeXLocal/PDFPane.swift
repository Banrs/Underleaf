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

    var body: some View {
        // The pane's actions (Compile, zoom, Share), then the page and
        // whether the preview is current in a secondary row, as the source
        // has its bar and location row: the two panes' rows and hairlines
        // line up. The find bar, while it shows, goes under them.
        PaneStack(finding: finding && project.pdfVersion > 0) {
            bar
        } location: {
            PageRow(project: project, controller: controller)
        } find: {
            findBar
        } content: {
            pages
        }
        // Edit › Find's items while the pages or the find bar have the
        // keyboard: the PDF's find, not the source's.
        .focusedValue(\.find, findAction)
        .onChange(of: controller.page) { _, page in project.pdfPage = page }
        // A new PDF leaves every match behind; the web closes the bar too.
        .onChange(of: project.pdfVersion) { _, _ in
            if finding { closeFind() }
        }
        // A request made while the pane was off screen waits for it to appear,
        // and each is taken once.
        .onChange(of: app.pdfRequest?.token, initial: true) { _, _ in
            guard let action = app.pdfRequest?.action else { return }
            app.pdfRequest = nil
            // After this update, so a PDF view that has just appeared has its document.
            Task { perform(action) }
        }
    }

    private var darkPaper: Bool { pdfPaper == "dark" || (pdfPaper == "auto" && colorScheme == .dark) }

    @ViewBuilder
    private var pages: some View {
        if project.pdfVersion > 0 {
            PDFRepresentable(project: project, controller: controller, darkPaper: darkPaper)
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
                GetMacTeXButton(prominent: true)
            }
        } else if project.result?.failed == true {
            ContentUnavailableView {
                Label("Build Failed", systemImage: "xmark.octagon")
            } description: {
                Text("The build made no PDF. The build panel shows what went wrong.")
            } actions: {
                // Nothing to offer while the panel already shows.
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
                // The empty state's one action, prominent. Content, not a
                // floating control, so not glass.
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

    /// Compile, zoom and Share, the PDF's actions, lined up with the
    /// source's bar beside it. Narrow panes shorten Compile to its symbol,
    /// then leave Share to the File menu, then zoom to the View menu.
    private var bar: some View {
        PaneBar {
            ViewThatFits(in: .horizontal) {
                actions(compact: false, share: true, zoom: true)
                actions(compact: true, share: true, zoom: true)
                actions(compact: true, share: false, zoom: true)
                actions(compact: true, share: true, zoom: false)
            }
        }
    }

    /// Compile at the leading edge; Share, then zoom, at the trailing.
    private func actions(compact: Bool, share: Bool, zoom: Bool) -> some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            compileControls(compact: compact)
            Spacer(minLength: 0)
            // Share before zoom, not at the bar's edge, where its picker
            // had no room in a full-screen window.
            if share { shareControl }
            if zoom { zoomControls }
        }
    }

    /// Overleaf's Recompile, the pane's one prominent control; while a build
    /// runs, Stop in its place, the system's spinner as its icon. Nothing
    /// follows it on its side of the bar, so the swap moves nothing.
    @ViewBuilder
    private func compileControls(compact: Bool) -> some View {
        if project.compiling {
            Button { project.stopCompile() } label: {
                let stop = Label { Text("Stop") } icon: { ProgressView().controlSize(.small) }
                if compact { stop.labelStyle(.iconOnly) } else { stop.labelStyle(.titleAndIcon) }
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Stop")
        } else {
            Button { app.perform(.compileRun, on: project) } label: {
                let compile = Label("Compile", systemImage: "play.fill")
                if compact { compile.labelStyle(SymbolOnTextLine()) } else { compile.labelStyle(.titleAndIcon) }
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(!app.isEnabled(.compileRun, on: project))
            .help("Compile")
            .accessibilityLabel("Compile")
        }
    }

    /// Zoom out | the scale | zoom in, the system's control group. The
    /// scale is a menu of ways to fit and preset scales, the one in use
    /// checked (while fitting, no preset is, even at a preset's scale). It
    /// keeps the width of its widest ("000%"), centred, so − and + stay put
    /// as it changes, as Pages' zoom keeps its own.
    private var zoomControls: some View {
        ControlGroup {
            Button("Zoom Out", systemImage: "minus") { controller.zoom(in: false) }
                .help("Zoom Out")
            Menu {
                CheckedItem("Fit Width", checked: controller.fit == .width) { controller.fitWidth() }
                CheckedItem("Fit Height", checked: controller.fit == .height) { controller.fitHeight() }
                Divider()
                ForEach(Self.zoomPresets, id: \.self) { percent in
                    CheckedItem("\(percent)%", checked: controller.fit == nil && "\(percent)%" == controller.zoomLabel) {
                        controller.setScale(CGFloat(percent) / 100)
                    }
                }
            } label: {
                Text("000%").hidden()
                    .overlay { Text(controller.zoomLabel) }
                    .monospacedDigit()
            }
            .menuIndicator(.hidden)
            .help("Zoom")
            // Named for what it sets, the scale its value, not a bare number.
            .accessibilityLabel("Scale")
            .accessibilityValue(controller.zoomLabel)
            Button("Zoom In", systemImage: "plus") { controller.zoom(in: true) }
                .help("Zoom In")
        }
        .fixedSize()
        .disabled(project.pdfVersion == 0)
        // One named group, its three controls inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom")
    }

    /// The system's share picker for the PDF, a group of its own so it is
    /// zoom's height beside it.
    @ViewBuilder
    private var shareControl: some View {
        if project.pdfVersion > 0, let url = project.pdfURL {
            ShareLink(item: url) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                .help("Share PDF")
                .inControlGroup()
        } else {
            Button("Share PDF", systemImage: "square.and.arrow.up") {}
                .disabled(true)
                .inControlGroup()
        }
    }

    private static let zoomPresets = [50, 75, 100, 125, 150, 200]

    /// Find in PDF, as the source's find bar is, without its replace row.
    private var findBar: some View {
        FindBar(query: $findQuery, prompt: "Find in PDF", focus: findFocus,
                matches: FindMatches(index: controller.matchIndex + 1, total: controller.matches.count,
                                     limited: controller.limited),
                searched: controller.query, step: controller.step, close: closeFind)
            .task(id: findQuery) {
                // Debounced like the web's, so typing doesn't search every prefix.
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled, PDFFind.normalize(findQuery) != controller.query {
                    controller.find(findQuery)
                }
            }
    }

    /// What Edit › Find's items do in the PDF (`FindActions`). It has no
    /// Replace; Use Selection for Find searches for the selected text, as
    /// Preview's does.
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

/// Whether the preview is current, and the page at the trailing end, as
/// quiet text in the row under the PDF's bar, as Preview shows the page:
/// paging is the keyboard's and the scroll's. The PDF's page, not the one
/// LaTeX prints: front matter and roman numbers make those differ.
private struct PageRow: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    let controller: PDFController

    var body: some View {
        SecondaryBar {
            if project.pdfVersion > 0, let freshness = project.pdfFreshness {
                Button {
                    if freshness == .edited { app.perform(.compileRun, on: project) } else { project.showBuildPanel() }
                } label: {
                    Label {
                        Text(freshness.title)
                    } icon: {
                        // A failed build's warning is the one colour here.
                        Image(systemName: freshness.systemImage)
                            .foregroundStyle(freshness == .lastSuccessful ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(freshness == .lastSuccessful
                      ? "The latest build failed; this is the last one that succeeded. Show Issues"
                      : "The preview doesn’t reflect the current source. Compile")
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            if project.pdfVersion > 0, controller.pageCount > 0 {
                Text("Page \(controller.page) of \(controller.pageCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: controller.page)
            }
        }
        .animation(.default, value: project.pdfFreshness)
    }
}

/// The find bar's rules, from the web's (web/src/findsession.js and
/// workspace.js `showCount`).
enum PDFFind {
    static let maxQuery = 256
    static let maxMatches = 5000

    static func normalize(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
    }
}

/// The PDF's setting, shared by Settings and the pane so its key and
/// default can't drift apart, as `EditorPrefs` are.
enum PDFPrefs {
    static let paperKey = "pdfPaper"
    /// "white", "dark", or "auto", which follows the app's appearance
    /// (web/src/prefs.js).
    static let paper = "white"
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
    /// The scale, as a percentage, whether fitting or set.
    var zoomLabel = "100%"
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
        zoomLabel = "\(Int((view.scaleFactor * 100).rounded()))%"
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

    /// A SyncTeX point for "the text you are looking at": the first line of
    /// text at or below a fifth of the way down the view. SyncTeX only
    /// resolves points that land on a glyph box, so a bare geometric guess —
    /// the page centre — would usually hit whitespace.
    func sourcePoint() -> (Int, CGPoint)? {
        guard let view, let document = view.document else { return nil }
        let probe = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - view.bounds.height * 0.2)
        guard let page = view.page(for: probe, nearest: true) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        var point = view.convert(probe, to: page)
        // Walk down the page in small steps until a line of text is found.
        while point.y > bounds.minY {
            if let line = page.selectionForLine(at: point), let text = line.string,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let box = line.bounds(for: page)
                point = CGPoint(x: box.midX, y: box.minY)
                break
            }
            point.y -= 6
        }
        return (document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: bounds))
    }
}

/// PDFView with a double-click that jumps to the source (inverse search).
final class SyncPDFView: PDFView {
    var onInverse: (Int, CGPoint) -> Void = { _, _ in }

    /// Dark paper, drawn as the web draws it (`.pdf-dark`): the rendered PDF
    /// inverted, then turned half way round the colour wheel so figures keep
    /// their hues. Under the filter the view keeps the light appearance,
    /// whose background and scrollers the inversion turns dark.
    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            wantsLayer = true
            layerUsesCoreImageFilters = true
            appearance = darkPaper ? NSAppearance(named: .aqua) : nil
            // A neutral near-white, which the inversion turns into dark
            // mode's under-page grey (40 of 255): Core Image inverts in
            // linear light, where 0.84 came out a mid grey. The tinted
            // under-page colour would come out olive.
            backgroundColor = darkPaper ? NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1) : .underPageBackgroundColor
            pageShadowsEnabled = !darkPaper
            let hue = CIFilter.hueAdjust()
            hue.angle = .pi
            contentFilters = darkPaper ? [CIFilter.colorInvert(), hue] : []
        }
    }

    /// The spot of the page at the top of what shows as a resize begins,
    /// put back at the top once laid out. PDFKit keeps its place against the
    /// scroll view's edge, not under its top inset, and loses a little with
    /// every step of a sliding pane: hiding the sidebar scrolled the pages
    /// 70 pt and the gap above page one away.
    private var anchor: (page: PDFPage, point: CGPoint)?

    /// Where the pages start showing, in the view: under the top inset.
    private var topEdge: CGFloat {
        let inset = scrollView?.contentInsets.top ?? 0
        return isFlipped ? bounds.minY + inset : bounds.maxY - inset
    }

    private var scrollView: NSScrollView? { documentView?.enclosingScrollView }

    override func setFrameSize(_ size: NSSize) {
        if anchor == nil, size != frame.size, frame.size != .zero,
           let page = page(for: CGPoint(x: bounds.midX, y: topEdge), nearest: true) {
            anchor = (page, convert(CGPoint(x: bounds.midX, y: topEdge), to: page))
        }
        if size != frame.size { resizes += 1 }
        super.setFrameSize(size)
    }

    /// Resizes so far, so the anchor is let go once they stop.
    private var resizes = 0

    override func layout() {
        super.layout()
        guard anchor != nil else { return }
        restoreAnchor()
        // PDFKit sets a fitted scale after the layout that resized it, and a
        // sliding pane resizes it many times: the one anchor, put back each
        // time, until the resizing has stopped.
        let resize = resizes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.resizes == resize else { return }
            self.restoreAnchor()
            self.anchor = nil
        }
    }

    private func restoreAnchor() {
        guard let (page, point) = anchor, let clip = scrollView?.contentView else { return }
        layoutDocumentView()
        let drift = convert(point, from: page).y - topEdge
        // Drift is measured in this view; the clip view scrolls the other
        // way when one of them is flipped.
        var origin = clip.bounds.origin
        origin.y += isFlipped == clip.isFlipped ? drift : -drift
        clip.scroll(to: origin)
        scrollView?.reflectScrolledClipView(clip)
    }

    /// The first page's top at the top of what shows, the gap above it, at
    /// the next layout: a new document is shown at the scroll view's edge.
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

    final class Coordinator {
        var version = 0
        var highlightToken = 0
        /// Following the view's page and scale, until the view goes.
        var watches: [Task<Void, Never>] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // An even margin of backdrop around every page, as Preview shows
        // one: the bars' 8 pt inset, so a page's edge lines up with the
        // controls over it. PDFKit's default left a sliver on one side only,
        // which beside the pane divider read as a thick, broken line.
        let inset = BarMetrics.inset
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: inset, bottom: inset, right: inset)
        // The gap above page one is the scroll view's, not a page margin:
        // fitting the width, PDFKit re-anchors page one's top edge to the top
        // of the view on every resize, scrolling a page margin out of sight.
        if let scroll = view.subviews.compactMap({ $0 as? NSScrollView }).first {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        }
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.onInverse = { [project] page, point in
            Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
        }
        controller.view = view
        let center = NotificationCenter.default
        // Each read once as it starts watching too: the first PDF's fitted
        // scale was set before the watch began, and the zoom showed 100%.
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
        let coordinator = context.coordinator
        // Taken as loaded only once it is: a new view tries again until then.
        if project.pdfVersion != coordinator.version, let url = project.pdfURL, reload(view, from: url) {
            coordinator.version = project.pdfVersion
        }
        if let highlight = project.highlight, highlight.token != coordinator.highlightToken {
            coordinator.highlightToken = highlight.token
            flash(highlight.loc, in: view)
        }
    }

    static func dismantleNSView(_ view: SyncPDFView, coordinator: Coordinator) {
        coordinator.watches.forEach { $0.cancel() }
    }

    /// Load a rebuilt PDF where the reader was: the same scroll offset at the
    /// same zoom, which, a document's pages keeping their size, is the same
    /// spot on the same page. Not `currentDestination`: it reads the top of
    /// the view, under the scroll view's top inset, and `go(to:)` puts it
    /// below that inset, so the pages crept down with every build. It is
    /// read whole: PDFKit reads a document from its file as it goes, and the
    /// next compile rewrites that file in place.
    private func reload(_ view: SyncPDFView, from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else { return false }
        hideLinkBorders(document)
        let clip = view.documentView?.enclosingScrollView?.contentView
        let offset = view.document == nil ? nil : clip?.bounds.origin
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        if !autoScales { view.scaleFactor = scale }
        // The first PDF of a reopened project opens at the page it was left at.
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
        return true
    }

    /// hyperref boxes every \ref and \cite in colour; pdf.js (browser,
    /// Windows) leaves the boxes out, so PDFKit does too. The links still work.
    private func hideLinkBorders(_ document: PDFDocument) {
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
            }
        }
    }

    /// Scroll to a forward-search result and flash it.
    private func flash(_ loc: ForwardLoc, in view: SyncPDFView) {
        guard let page = view.document?.page(at: Int(loc.page) - 1) else { return }
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        let mark = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(0.45)
        page.addAnnotation(mark)
        view.go(to: rect.insetBy(dx: 0, dy: -view.bounds.height / 3), on: page)
        // As long as the web's flash fades (web/styles.css `.sync-flash`).
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            page.removeAnnotation(mark)
        }
    }
}
