import PDFKit
import SwiftUI

/// The compiled PDF in PDFKit: native rendering, selection, zoom and find.
struct PDFPane: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var controller = PDFController()
    @State private var findQuery = ""
    @State private var finding = false
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if project.pdfVersion > 0 {
                PDFRepresentable(project: project, controller: controller)
            } else {
                ContentUnavailableView(
                    project.texAvailable ? "No PDF Yet" : "TeX Isn’t Installed",
                    systemImage: "doc.richtext",
                    description: Text(project.texAvailable
                        ? "Compile to preview your document."
                        : "Install MacTeX to enable compilation.")
                )
            }
        }
        .onChange(of: app.pdfRequest?.token) { _, _ in
            guard let action = app.pdfRequest?.action else { return }
            switch action {
            case .zoomIn: controller.zoom(in: true)
            case .zoomOut: controller.zoom(in: false)
            case .fitWidth: controller.fitWidth()
            case .fitHeight: controller.fitHeight()
            case .find: finding = true; findFocused = true
            case .inverseFromView:
                if case let (page, point)? = controller.sourcePoint() {
                    Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if finding {
                TextField("Find in PDF", text: $findQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFocused)
                    .frame(maxWidth: 220)
                    .onSubmit { controller.find(findQuery) }
                    .onChange(of: findQuery) { _, q in controller.find(q) }
                Text(controller.matches.isEmpty ? (findQuery.isEmpty ? "" : "No matches")
                     : "\(controller.matchIndex + 1) of \(controller.matches.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ControlGroup {
                    Button("Previous", systemImage: "chevron.up") { controller.step(-1) }
                    Button("Next", systemImage: "chevron.down") { controller.step(1) }
                }
                .fixedSize()
                .disabled(controller.matches.isEmpty)
                Button("Done") {
                    finding = false
                    findQuery = ""
                    controller.find("")
                }
            } else if controller.pageCount > 0 {
                Text("Page \(controller.page) of \(controller.pageCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { controller.zoom(in: false) }
                Button("Fit Width", systemImage: "arrow.left.and.right") { controller.fitWidth() }
                Button("Zoom In", systemImage: "plus.magnifyingglass") { controller.zoom(in: true) }
            }
            .fixedSize()
            .disabled(project.pdfVersion == 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 36)
    }
}

/// What the pane's controls and the menus ask of the PDF view.
@MainActor @Observable
final class PDFController {
    @ObservationIgnored weak var view: SyncPDFView?
    var page = 0
    var pageCount = 0
    var matches: [PDFSelection] = []
    var matchIndex = 0

    func zoom(in zoomIn: Bool) {
        guard let view else { return }
        view.autoScales = false
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    /// In a continuous single-page layout, auto-scaling fits the page width.
    func fitWidth() {
        view?.autoScales = true
    }

    func fitHeight() {
        guard let view, let page = view.currentPage else { return }
        view.autoScales = false
        view.scaleFactor = view.bounds.height / page.bounds(for: view.displayBox).height
    }

    func find(_ query: String) {
        guard let view, let document = view.document else { return }
        matches = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        matchIndex = 0
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
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

    final class Coordinator {
        var version = 0
        var highlightToken = 0
        var pageObserver: NSObjectProtocol?
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
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        let coordinator = context.coordinator
        if project.pdfVersion != coordinator.version, let url = project.pdfURL {
            coordinator.version = project.pdfVersion
            reload(view, from: url)
        }
        if let highlight = project.highlight, highlight.token != coordinator.highlightToken {
            coordinator.highlightToken = highlight.token
            flash(highlight.loc, in: view)
        }
    }

    static func dismantleNSView(_ view: SyncPDFView, coordinator: Coordinator) {
        if let observer = coordinator.pageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Load a rebuilt PDF where the reader was: same page, same zoom.
    private func reload(_ view: SyncPDFView, from url: URL) {
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        guard let document = PDFDocument(url: url) else { return }
        view.document = document
        if !autoScales { view.scaleFactor = scale }
        if let pageIndex, let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            view.go(to: page)
        }
        controller.pageCount = document.pageCount
        controller.page = (pageIndex ?? 0) + 1
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
