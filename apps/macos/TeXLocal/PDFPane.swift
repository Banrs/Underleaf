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
        // The pane's own bars over it, stacked rather than overlaid: they are
        // opaque, so a page scrolled beneath them was only hidden — its top
        // and top margin sat behind them.
        VStack(spacing: 0) {
            bar
            pages
        }
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

    @ViewBuilder
    private var pages: some View {
        Group {
            if project.pdfVersion > 0 {
                PDFRepresentable(
                    project: project, controller: controller,
                    // "auto" follows the app's appearance (web/src/prefs.js).
                    darkPaper: pdfPaper == "dark" || (pdfPaper == "auto" && colorScheme == .dark)
                )
            } else {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                Link("Get MacTeX", destination: macTeXURL)
            }
        } else if project.result?.ok == false {
            ContentUnavailableView {
                Label("Build Failed", systemImage: "xmark.octagon")
            } description: {
                Text("The build made no PDF. The build panel shows what went wrong.")
            } actions: {
                // Nothing to offer while the panel already shows.
                if !project.showLogs {
                    Button("Show Build Panel") {
                        // The log when no error was parsed out of it.
                        project.panelTab = project.result?.errors.isEmpty == false ? .issues : .log
                        project.showLogs = true
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Yet", systemImage: "doc.richtext")
            } description: {
                Text("Compile to preview your document.")
            } actions: {
                Button("Compile") { app.perform(.compileRun) }
                    .disabled(!app.isEnabled(.compileRun))
            }
        }
    }

    private func perform(_ action: PDFAction) {
        switch action {
        case .zoomIn: controller.zoom(in: true)
        case .zoomOut: controller.zoom(in: false)
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
                        actions(compact: false, zoom: true)
                        actions(compact: true, zoom: true)
                        actions(compact: true, zoom: false)
                    }
                }
            }
            SecondaryBar(spacing: BarMetrics.itemSpacing) {
                status
                Spacer(minLength: 0)
            }
            Divider()
        }
    }

    /// Compile at the leading edge; zoom, then Share, at the trailing, each
    /// a group with the source bar's separator between them.
    private func actions(compact: Bool, zoom: Bool) -> some View {
        HStack(spacing: BarMetrics.spacing) {
            compileControls(compact: compact)
            Spacer(minLength: BarMetrics.groupSpacing)
            if zoom {
                zoomControls
                ToolSeparator()
            }
            share
        }
    }

    /// Overleaf's Recompile, over the PDF it makes: the pane's one
    /// prominent control; while a build runs, a
    /// spinner and Stop in its place.
    @ViewBuilder
    private func compileControls(compact: Bool) -> some View {
        if project.compiling {
            HStack(spacing: BarMetrics.groupSpacing) {
                ProgressView().controlSize(.small)
                Button("Stop", systemImage: "stop.fill") { project.stopCompile() }
                    .labelStyle(.iconOnly)
                    .help("Stop")
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
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(!app.isEnabled(.compileRun))
            .help("Compile")
        }
    }

    @ViewBuilder
    private var share: some View {
        ShareButton(url: project.pdfVersion > 0 ? project.pdfURL : nil)
            .labelStyle(.iconOnly)
            .fixedSize()
    }

    /// The page, and whether the PDF still matches the source.
    private var status: some View {
        Group {
            if let freshness = project.pdfFreshness {
                Label {
                    Text(freshness.title)
                } icon: {
                    // A failed build's warning badge is the one colour here.
                    Image(systemName: freshness.systemImage)
                        .foregroundStyle(freshness == .lastSuccessful ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .foregroundStyle(.secondary)
                .help(freshness == .lastSuccessful
                      ? "The latest build failed; this is the last one that succeeded"
                      : "The preview doesn’t reflect the current source")
            }
            if controller.pageCount > 0 {
                Text("Page \(controller.page) of \(controller.pageCount)")
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var findControls: some View {
        SearchField(text: $findQuery, prompt: "Find in PDF", focus: findFocus, step: controller.step, close: closeFind)
            .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: .infinity)
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
        ToolGroup(items: [
            Segment(id: "previous", title: "Previous Match", systemImage: "chevron.up",
                    enabled: !controller.matches.isEmpty) { controller.step(-1) },
            Segment(id: "next", title: "Next Match", systemImage: "chevron.down",
                    enabled: !controller.matches.isEmpty) { controller.step(1) },
        ])
        // A text action, so a push button, apart from the icon buttons.
        Button("Done") { closeFind() }
            .buttonStyle(.bordered)
            .fixedSize()
    }

    /// The scale, a menu of ways to fit and preset scales, the one in use
    /// checked. A menu rather than a pop-up, as the scale is any percentage,
    /// not only a preset's; bordered, with the system's indicator, as the
    /// source bar's Section Level is: the bars' values are bordered, their
    /// actions flat.
    private var zoomMenu: some View {
        Menu {
            // The fitting in use is checked, as Preview's is; while fitting,
            // no preset is, even at a preset's scale.
            Picker("Fit", selection: Binding(
                get: { controller.fit },
                set: { fit in
                    switch fit {
                    case .width: controller.fitWidth()
                    case .height: controller.fitHeight()
                    case nil: break
                    }
                }
            )) {
                Text("Fit Width").tag(Optional(PDFController.Fit.width))
                Text("Fit Height").tag(Optional(PDFController.Fit.height))
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Zoom", selection: Binding(
                get: { controller.fit == nil ? Self.zoomPresets.first { "\($0)%" == controller.zoomLabel } : nil },
                set: { if let percent = $0 { controller.setScale(CGFloat(percent) / 100) } }
            )) {
                ForEach(Self.zoomPresets, id: \.self) { Text("\($0)%").tag(Optional($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(controller.zoomLabel).monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Zoom")
        .accessibilityLabel("Zoom")
        .accessibilityValue(controller.zoomLabel)
    }

    private static let zoomPresets = [50, 75, 100, 125, 150, 200]

    /// Zoom out, the scale, zoom in: one group, as Preview's zoom is — the
    /// web's zoom control (workspace.js `zoomButton`).
    private var zoomControls: some View {
        // Not the View menu's commands: their route (`requestPDF`) also
        // hides the panel.
        HStack(spacing: 0) {
            Button("Zoom Out", systemImage: "minus") { controller.zoom(in: false) }
                .help("Zoom Out")
            zoomMenu
            Button("Zoom In", systemImage: "plus") { controller.zoom(in: true) }
                .help("Zoom In")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
        .disabled(project.pdfVersion == 0)
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

/// A choice in a search field's own menu (Match Case, Whole Words…).
struct SearchOption {
    let title: String
    let isOn: Binding<Bool>
}

/// A search field in which Return steps to the next match, Shift-Return to
/// the previous one, and Escape closes the bar — keys a SwiftUI text field
/// keeps to itself. Without `step` or `close`, those keys do what they
/// usually do. `options` go in the field's own menu, under its magnifier,
/// as Xcode's and Safari's find options do. Without its magnifier
/// (`searches` false) it is the find bar's replace field: the search
/// field's shape and height at every control size, which AppKit's plain
/// text field keeps at the regular size; Return then calls `submit`.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var searches = true
    var focus = 0
    var options: [SearchOption] = []
    var step: (@MainActor (Int) -> Void)?
    var submit: (@MainActor () -> Void)?
    var close: (@MainActor () -> Void)?

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField
        var focus = 0
        /// The options' states the field's menu was last made with.
        var optionStates: [Bool]?

        init(_ field: SearchField) {
            self.field = field
        }

        // Typing, and the field's clear button, both send the action.
        @objc func search(_ sender: NSSearchField) {
            field.text = sender.stringValue
        }

        @objc func toggleOption(_ sender: NSMenuItem) {
            guard field.options.indices.contains(sender.tag) else { return }
            field.options[sender.tag].isOn.wrappedValue.toggle()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let step = field.step {
                    step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                } else if let submit = field.submit {
                    submit()
                } else {
                    return false
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let close = field.close else { return false }
                close()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let view = NSSearchField()
        view.sendsSearchStringImmediately = true
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.search(_:))
        return view
    }

    /// As wide as it is offered, however narrow: the frame around it sets
    /// its least and ideal widths.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = self
        view.placeholderString = prompt
        view.controlSize = NSControl.ControlSize(context.environment.controlSize)
        view.font = .systemFont(ofSize: NSFont.systemFontSize(for: view.controlSize))
        // No magnifier, but its room kept, so the text starts where the find
        // field's does above it: an empty menu makes AppKit lay out the same
        // magnifier-with-menu button as the find field's options menu does.
        // After the size and the menu, which both set the image again.
        if !searches, view.searchMenuTemplate == nil {
            view.searchMenuTemplate = NSMenu(title: "")
        }
        if !searches, let button = (view.cell as? NSSearchFieldCell)?.searchButtonCell {
            button.image = nil
            button.alternateImage = nil
            button.isEnabled = false
        }
        if view.stringValue != text { view.stringValue = text }
        // The field copies its menu, so it is made again when a state changes.
        let states = options.map(\.isOn.wrappedValue)
        if !options.isEmpty, coordinator.optionStates != states {
            coordinator.optionStates = states
            let menu = NSMenu(title: "Find Options")
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option.title, action: #selector(Coordinator.toggleOption(_:)), keyEquivalent: "")
                item.target = coordinator
                item.tag = index
                item.state = option.isOn.wrappedValue ? .on : .off
                menu.addItem(item)
            }
            view.searchMenuTemplate = menu
        }
        if coordinator.focus != focus {
            coordinator.focus = focus
            // Once the field is in its window. Taking focus selects the text.
            Task { @MainActor in view.window?.makeFirstResponder(view) }
        }
    }
}

extension NSControl.ControlSize {
    /// AppKit's size for SwiftUI's, so a wrapped control matches its neighbours.
    init(_ size: ControlSize) {
        self = switch size {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        case .extraLarge: .extraLarge
        @unknown default: .regular
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
    /// The scale, as a percentage, whether fitting or set.
    var zoomLabel = "100%"
    /// How the page is fitted to the view, or nil at a set scale.
    enum Fit { case width, height }
    private(set) var fit: Fit? = .width

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

    @MainActor
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
        // An even margin of backdrop around every page, as Preview shows
        // one: the bars' 8 pt inset, so a page's edge lines up with the
        // controls over it. PDFKit's default left a sliver on one side only,
        // which beside the pane divider read as a thick, broken line.
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        // The gap above page one is the scroll view's, not a page margin:
        // fitting the width, PDFKit re-anchors page one's top edge to the top
        // of the view on every resize, scrolling a page margin out of sight.
        if let scroll = view.subviews.compactMap({ $0 as? NSScrollView }).first {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        }
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
        hideLinkBorders(document)
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

    /// hyperref boxes every \ref and \cite in colour unless told not to.
    /// pdf.js, which the browser and Windows draw with, leaves the boxes out,
    /// so PDFKit does too. The links still work.
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            page.removeAnnotation(mark)
        }
    }
}

/// Shares the PDF with AppKit's picker, opened from the button itself.
private struct ShareButton: View {
    let url: URL?
    @State private var anchor: NSView?

    var body: some View {
        Button("Share PDF", systemImage: "square.and.arrow.up") {
            guard let url, let anchor else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        .disabled(url == nil)
        .background(ViewAnchor(view: $anchor))
        .help("Share PDF")
    }
}

/// An AppKit view where a SwiftUI view is, for AppKit to anchor to.
private struct ViewAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        Task { @MainActor in view = anchor }
        return anchor
    }

    func updateNSView(_ anchor: NSView, context: Context) {}
}
