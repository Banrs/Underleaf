import CoreImage.CIFilterBuiltins
import PDFKit
import SwiftUI

/// The compiled PDF in PDFKit: native rendering, selection, zoom and find.
struct PDFPane: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var controller = PDFController()
    @State private var findQuery = ""
    @State private var finding = false
    /// Bumped to put the cursor in the find field, its text selected.
    @State private var findFocus = 0
    @AppStorage("pdfPaper") private var pdfPaper = "white"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if project.pdfVersion > 0 {
                PDFRepresentable(
                    project: project, controller: controller,
                    // "auto" follows the app's appearance (web/src/prefs.js).
                    darkPaper: pdfPaper == "dark" || (pdfPaper == "auto" && colorScheme == .dark)
                )
            } else {
                ContentUnavailableView(
                    project.texAvailable ? "No PDF Yet" : "TeX Isn’t Installed",
                    systemImage: "doc.richtext",
                    description: Text(project.texAvailable
                        ? "Compile to preview your document."
                        : "Install MacTeX to enable compilation.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The pane's own bar, as Xcode's canvas has one: what is scoped to
        // the PDF — its page, whether it is current, its zoom, finding in it —
        // rather than to the document the window toolbar acts on. A system
        // bar, so the pages scroll beneath it with the edge effect.
        .safeAreaBar(edge: .top) { bar }
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

    private func perform(_ action: PDFAction) {
        switch action {
        case .zoomIn: controller.zoom(in: true)
        case .zoomOut: controller.zoom(in: false)
        case .fitWidth: controller.fitWidth()
        case .fitHeight: controller.fitHeight()
        case .find: finding = true; findFocus += 1
        case .inverseFromView:
            if case let (page, point)? = controller.sourcePoint() {
                Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
            }
        }
    }

    /// Two rows lined up with the source's: actions — Compile, zoom, Share —
    /// then where you are: the page, and whether it is current. Finding takes
    /// the actions row, as Preview's find does.
    private var bar: some View {
        VStack(spacing: 0) {
            PaneBar {
                if finding {
                    findControls
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { compileControls(compact: false); Spacer(minLength: 0); zoomControls; share }
                        HStack(spacing: 12) { compileControls(compact: true); Spacer(minLength: 0); zoomControls; share }
                        HStack(spacing: 12) { compileControls(compact: true); Spacer(minLength: 0); share }
                    }
                }
            }
            LocationBar {
                status
                Spacer(minLength: 0)
            }
        }
    }

    /// Overleaf's Recompile, over the PDF it makes: the pane's one
    /// prominent control, in prominent Liquid Glass; while a build runs, a
    /// spinner and Stop in its place.
    @ViewBuilder
    private func compileControls(compact: Bool) -> some View {
        if project.compiling {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Button("Stop", systemImage: "stop.fill") { project.stopCompile() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Stop (⌘.)")
            }
            .fixedSize()
        } else {
            Button { app.perform(.compileRun) } label: {
                if compact {
                    Label("Compile", systemImage: "play.fill").labelStyle(.iconOnly)
                } else {
                    Label("Compile", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .fixedSize()
            .disabled(!app.isEnabled(.compileRun))
            .help(project.texAvailable ? "Compile (⌘↩)" : "Install TeX to compile")
        }
    }

    @ViewBuilder
    private var share: some View {
        Group {
            if let url = project.pdfURL, project.pdfVersion > 0 {
                ShareLink(item: url) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                    .help("Share PDF")
            } else {
                Button("Share PDF", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
                    .help("Compile to share the PDF")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
    }

    /// The page, and whether the PDF still matches the source.
    private var status: some View {
        HStack(spacing: 12) {
            if let freshness = project.pdfFreshness {
                Label(freshness.title, systemImage: freshness.systemImage)
                    .foregroundStyle(freshness == .lastSuccessful ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(freshness == .lastSuccessful
                          ? "The latest build failed; this is the last one that succeeded"
                          : "The preview doesn’t reflect the current source")
            }
            if controller.pageCount > 0 {
                Text("Page \(controller.page) of \(controller.pageCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var findControls: some View {
        PDFFindField(text: $findQuery, focus: findFocus, step: controller.step, close: closeFind)
            .frame(minWidth: 100, maxWidth: .infinity)
            .task(id: findQuery) {
                // Debounced like the web's, so typing doesn't search every prefix.
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled, PDFFind.normalize(findQuery) != controller.query {
                    controller.find(findQuery)
                }
            }
        Text(PDFFind.countLabel(
            query: controller.query, total: controller.matches.count,
            index: controller.matchIndex + 1, limited: controller.limited
        ))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        ControlGroup {
            Button("Previous Match", systemImage: "chevron.up") { controller.step(-1) }
                .help("Previous Match (⇧↩)")
            Button("Next Match", systemImage: "chevron.down") { controller.step(1) }
                .help("Next Match (↩)")
        }
        .fixedSize()
        .disabled(controller.matches.isEmpty)
        Button("Done") { closeFind() }
            .fixedSize()
    }

    /// Zoom out, the zoom level with its presets, zoom in — the web's zoom
    /// control (workspace.js `zoomButton`).
    /// Out, the level (a menu), in: the kit's Medium segmented control in
    /// glass — 24 pt segments, 3 pt separator slots, 2 pt inside — whose
    /// separators set the menu apart from the two buttons.
    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { controller.zoom(in: false) }
                .frame(width: glassSegment, height: glassHeight)
                .contentShape(.rect)
                .help("Zoom Out (⌘−)")
            zoomSeparator
            Menu {
                Button("Fit Width") { controller.fitWidth() }
                Button("Fit Height") { controller.fitHeight() }
                Divider()
                ForEach([50, 75, 100, 125, 150, 200], id: \.self) { percent in
                    Button("\(percent)%") { controller.setScale(CGFloat(percent) / 100) }
                }
            } label: {
                // One width for every level, so the pill doesn't resize as it
                // zooms (pinching steps through dozens).
                Text(controller.zoomLabel)
                    .monospacedDigit()
                    .frame(width: 72, height: glassHeight)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .help("Zoom")
            zoomSeparator
            Button("Zoom In", systemImage: "plus.magnifyingglass") { controller.zoom(in: true) }
                .frame(width: glassSegment, height: glassHeight)
                .contentShape(.rect)
                .help("Zoom In (⌘+)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, glassPadding)
        .frame(height: glassHeight)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
        .disabled(project.pdfVersion == 0)
    }

    /// The kit's Medium segmented separator: a 1 x 16 pt line in a 3 pt slot.
    private var zoomSeparator: some View {
        Rectangle().fill(.separator).frame(width: 1, height: glassSeparator).padding(.horizontal, 1)
    }

    /// web/src/workspace.js `closePdfFind`: the bar goes, and its query and
    /// highlights with it.
    private func closeFind() {
        finding = false
        findQuery = ""
        controller.find("")
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

    /// "3 of 12", "1 of 5000+" past the cap, "Not found", or nothing before a
    /// search. `index` counts from 1.
    static func countLabel(query: String, total: Int, index: Int, limited: Bool) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return "Not found" }
        return "\(index) of \(total)\(limited ? "+" : "")"
    }
}

/// The find field: a search field in which Return steps to the next match,
/// Shift-Return to the previous one, and Escape closes the bar — keys a
/// SwiftUI text field keeps to itself.
private struct PDFFindField: NSViewRepresentable {
    @Binding var text: String
    let focus: Int
    let step: @MainActor (Int) -> Void
    let close: @MainActor () -> Void

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: PDFFindField
        var focus = 0

        init(_ field: PDFFindField) {
            self.field = field
        }

        // Typing, and the field's clear button, both send the action.
        @objc func search(_ sender: NSSearchField) {
            field.text = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                field.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.close()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let view = NSSearchField()
        view.placeholderString = "Find in PDF"
        view.sendsSearchStringImmediately = true
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.search(_:))
        return view
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        context.coordinator.field = self
        if view.stringValue != text { view.stringValue = text }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            // Once the field is in its window. Taking focus selects the text.
            Task { @MainActor in view.window?.makeFirstResponder(view) }
        }
    }
}

/// What the pane's controls and the menus ask of the PDF view.
@MainActor @Observable
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
    /// "Fit Width" while the view fits the page to its width, else the scale.
    var zoomLabel = "Fit Width"

    func scaleChanged() {
        guard let view else { return }
        zoomLabel = view.autoScales ? "Fit Width" : "\(Int((view.scaleFactor * 100).rounded()))%"
    }

    func setScale(_ scale: CGFloat) {
        guard let view else { return }
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        guard let view else { return }
        view.autoScales = false
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    /// In a continuous single-page layout, auto-scaling fits the page width.
    func fitWidth() {
        view?.autoScales = true
        scaleChanged()
    }

    func fitHeight() {
        guard let view, let page = view.currentPage else { return }
        view.autoScales = false
        view.scaleFactor = view.bounds.height / page.bounds(for: view.displayBox).height
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
            // A neutral light grey, which the inversion turns neutral dark;
            // the tinted under-page colour would come out olive.
            backgroundColor = darkPaper ? NSColor(white: 0.84, alpha: 1) : .underPageBackgroundColor
            pageShadowsEnabled = !darkPaper
            let hue = CIFilter.hueAdjust()
            hue.angle = .pi
            contentFilters = darkPaper ? [CIFilter.colorInvert(), hue] : []
        }
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
        var pageObserver: NSObjectProtocol?
        var scaleObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.onInverse = { [project] page, point in
            Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
        }
        controller.view = view
        context.coordinator.pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [controller] _ in
            MainActor.assumeIsolated {
                guard let view = controller.view, let document = view.document, let page = view.currentPage else { return }
                controller.page = document.index(for: page) + 1
                controller.pageCount = document.pageCount
            }
        }
        context.coordinator.scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [controller] _ in
            MainActor.assumeIsolated { controller.scaleChanged() }
        }
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
        for observer in [coordinator.pageObserver, coordinator.scaleObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Load a rebuilt PDF where the reader was: same spot on the same page,
    /// same zoom. It is read whole: PDFKit reads a document from its file as
    /// it goes, and the next compile rewrites that file in place.
    private func reload(_ view: SyncPDFView, from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else { return false }
        let spot = view.currentDestination
        let pageIndex = spot?.page.flatMap { view.document?.index(for: $0) }
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        if !autoScales { view.scaleFactor = scale }
        if let pageIndex, let spot, let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: spot.point))
        }
        controller.pageCount = document.pageCount
        controller.page = (pageIndex ?? 0) + 1
        return true
    }

    /// Scroll to a forward-search result and flash it.
    private func flash(_ loc: ForwardLoc, in view: SyncPDFView) {
        guard let page = view.document?.page(at: Int(loc.page) - 1) else { return }
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        let mark = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(0.45)
        page.addAnnotation(mark)
        view.go(to: rect.insetBy(dx: 0, dy: -view.bounds.height / 3), on: page)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            page.removeAnnotation(mark)
        }
    }
}
