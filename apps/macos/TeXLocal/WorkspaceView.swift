import SwiftUI

/// An open project: sidebar | source | PDF, each column's tools in the toolbar over it.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var fit = ToolbarFit()

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            // With three columns, hiding the sidebar alone is "double column".
            get: { app.sidebarVisible ? .all : .doubleColumn },
            set: { app.sidebarVisible = $0 == .all }
        )) {
            NavigatorView(project: project)
                // Once per project: its panes keep the views they were made with.
                .id(ObjectIdentifier(project))
                .navigationSplitViewColumnWidth(min: ColumnMetrics.sidebarWidth.lowerBound,
                                                ideal: ColumnMetrics.sidebarIdeal,
                                                max: ColumnMetrics.sidebarWidth.upperBound)
        } content: {
            EditorArea(project: project, fit: fit)
                .id(ObjectIdentifier(project))
                .navigationSplitViewColumnWidth(
                    min: ColumnMetrics.sourceMinimum + (app.sidebarVisible ? 0 : ColumnMetrics.windowControls),
                    ideal: ColumnMetrics.ideal)
        } detail: {
            // Collapsed while hidden, never rebuilt (`PDFColumn`).
            PDFPane(project: project, fit: fit)
                .id(ObjectIdentifier(project))
                .navigationSplitViewColumnWidth(min: ColumnMetrics.pdfMinimum, ideal: ColumnMetrics.ideal)
        }
        .navigationTitle(project.openPath.map { ($0 as NSString).lastPathComponent } ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        // From a background, so the workspace keeps its identity as the document comes and goes.
        .background {
            if let url = project.openURL { Color.clear.navigationDocument(url) }
        }
        .background { FindMenuTarget(project: project) }
        // At the root: the columns are hosted apart, each in the split's own controller.
        .focusedSceneValue(project)
        .fileImporter(isPresented: $app.addingFiles, allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await project.importFiles(urls) }
            case .failure(let error): app.alert = AppAlert("Couldn’t Add the Files", error)
            }
        }
        .fileDialogConfirmationLabel("Add")
        .fileExporter(isPresented: Binding(presenting: $app.exporting), item: app.exporting,
                      contentTypes: app.exporting.map { [$0.type] } ?? [],
                      defaultFilename: app.exporting?.name) { [name = app.exporting?.name ?? ""] result in
            if case .failure(let error) = result { app.alert = AppAlert("Couldn’t Save “\(name)”", error) }
        }
        // Save PDF As… saves; a zip is exported.
        .fileExporterFilenameLabel(app.exporting?.type == .pdf ? "Save As:" : "Export As:")
        .fileDialogConfirmationLabel(app.exporting?.type == .pdf ? "Save" : "Export")
        .sheet(item: $app.prompt) { prompt in
            switch prompt {
            case .newFile: NewEntrySheet(project: project, directory: false)
            case .newFolder: NewEntrySheet(project: project, directory: true)
            case .gotoLine: GoToLineSheet(project: project)
            }
        }
        .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
            Button("Replace") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                .keyboardShortcut(.defaultAction)
            Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
            Button("Stop", role: .cancel) {}
        } message: { clash in
            Text(clash.message)
        }
        .alert(project.diskConflict.map { "“\(($0 as NSString).lastPathComponent)” Changed on Disk" } ?? "",
               item: $project.diskConflict) { _ in
            Button("Keep Editing", role: .cancel) { project.keepEdits() }
            // It discards the edits: never the default button.
            Button("Revert", role: .destructive) { Task { await project.revertToDisk() } }
        } message: { path in
            Text("Another app changed \(path) while it has unsaved changes here. Revert to the version on disk, or keep editing and save over it.")
        }
    }
}

/// Column widths. The minimums hold each column's default tools with the optional
/// ones folded; checked by `ToolbarFit` in DEBUG. Constants: live toolbar geometry
/// fed to column widths loops layout (27.2).
enum ColumnMetrics {
    static let sidebarWidth: ClosedRange<CGFloat> = 200...320
    /// UI kit: the window sidebar is 256 pt.
    static let sidebarIdeal: CGFloat = 256
    static let sourceMinimum: CGFloat = 360
    /// The traffic lights and the sidebar toggle, over the source while the sidebar is hidden.
    static let windowControls: CGFloat = 132
    static let pdfMinimum: CGFloat = 280
    /// Half each of the default window's room past the sidebar.
    static var ideal: CGFloat { (WindowMetrics.projectDefault.width - sidebarIdeal) / 2 }
}

/// Folds each column's optional toolbar tools so they never run past its divider,
/// where the toolbar would draw its own section line off the column's. Decided from
/// the toolbar's measured layout; its outputs only add or remove toolbar items.
/// Items a user adds make the default optional tools fold first but never fold
/// themselves (removing customizable items would disturb the saved configuration),
/// so with enough of them a section can still part from the divider.
@Observable
final class ToolbarFit {
    enum Column { case source, pdf }

    enum Item: String, CaseIterable {
        case back, sectionLevelPopUp, sectionLevelIcon, format, insert, undo, math, references, figures, lists
        case zoom, share, freshness, settings, compile, togglePDF
    }

    enum SectionLevelStyle { case popUp, icon, hidden }

    private(set) var sectionLevelStyle = SectionLevelStyle.popUp
    private(set) var showsZoom = true
    private(set) var showsShare = true

    private static let sourceItems: Set<Item> = [.back, .sectionLevelPopUp, .sectionLevelIcon, .format, .insert,
                                                 .undo, .math, .references, .figures, .lists]
    private static let pdfItems = Set(Item.allCases).subtracting(sourceItems)
    /// After the PDF's flexible spacer.
    private static let trailingGroup: Set<Item> = [.freshness, .settings, .compile, .togglePDF]
    /// Added only with Customize Toolbar.
    private static let nonDefault: Set<Item> = [.undo, .math, .references, .figures, .lists]

    // MARK: State

    private struct WeakView { weak var view: NSView? }

    /// A toolbar section: the PDF's own and the source's while the PDF shows; one
    /// section for everything while it's hidden.
    private enum Section { case source, pdf, combined }

    /// A fold step, keyed by the level it reaches.
    private struct Step: Hashable {
        let column: Column
        let level: Int
        /// The PDF's last step frees the spacer's minimum in its own section, an item gap when combined.
        let combined: Bool

        init(_ column: Column, _ level: Int, in section: Section) {
            self.column = column
            self.level = level
            combined = column == .pdf && section == .combined
        }
    }

    /// A step the toolbar hasn't shown yet: decisions wait for it, then learn its width.
    private struct Pending {
        let step: Step?
        let folding: Bool
        let before: Set<Item>
        let expected: Set<Item>
        let width: CGFloat
        var measures = 0
    }

    @ObservationIgnored private var probes: [Item: WeakView] = [:]
    @ObservationIgnored private var columns: [Column: WeakView] = [:]
    @ObservationIgnored private var measureScheduled = false
    @ObservationIgnored private var pdfShown: Bool?
    /// 0 pop-up, 1 icon, 2 hidden.
    @ObservationIgnored private var sourceLevel = 0
    /// 0 zoom and Share, 1 Share, 2 neither.
    @ObservationIgnored private var pdfLevel = 0
    @ObservationIgnored private var freed: [Step: CGFloat] = [:]
    @ObservationIgnored private var pending: [Section: Pending] = [:]
    /// The PDF section's leading inset, by its first item: each item's glass pads its content differently.
    @ObservationIgnored private var pdfInsets: [Item: CGFloat] = [:]
    /// The source section's trailing inset, by its last item.
    @ObservationIgnored private var sourceInsets: [Item: CGFloat] = [:]
    /// The least the PDF's flexible spacer shrinks to.
    @ObservationIgnored private var spacerMin: CGFloat?
    /// The least gap from Back to the next item (the title's room), and whether an
    /// overflowing source has shown it. Tools after the title hug the section's
    /// trailing edge, so their room shows only in this gap.
    @ObservationIgnored private var leadMin: CGFloat?
    @ObservationIgnored private var leadExact = false
    #if DEBUG
    @ObservationIgnored private var overfull: [Section: Int] = [:]
    #endif

    // MARK: Inputs

    fileprivate func register(_ view: NSView, as item: Item) {
        probes[item] = WeakView(view: view)
        setNeedsMeasure()
    }

    fileprivate func unregister(_ view: NSView, as item: Item) {
        guard probes[item]?.view === view else { return }
        probes[item] = nil
        setNeedsMeasure()
    }

    fileprivate func register(_ view: NSView, as column: Column, collapsed: Bool) {
        columns[column] = WeakView(view: view)
        if column == .pdf, pdfShown == nil { pdfShown = !collapsed }
        setNeedsMeasure()
    }

    fileprivate func unregister(_ view: NSView, as column: Column) {
        guard columns[column]?.view === view else { return }
        columns[column] = nil
    }

    func setNeedsMeasure() {
        guard !measureScheduled else { return }
        measureScheduled = true
        // Once the current change is done. Common modes: a divider drag or a live
        // resize tracks events outside the default mode.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    /// Called by `PDFColumn` before it opens or collapses the PDF. Opening, the
    /// source folds to its coming edge at once, so its tools never pass under the PDF.
    func pdfColumnChanging(shown: Bool, sourceMaxX: CGFloat?) {
        pdfShown = shown
        pending = [:]
        defer { publish() }
        guard shown else {
            pdfLevel = max(pdfLevel, 1)
            return
        }
        let row = Row(Self.sourceItems, frames())
        // The tools move to the coming edge; only their widths and the title's room carry over.
        guard let sourceMaxX, leadExact, let leadMin, let back = row.back, let next = row.afterBack,
              let last = row.last else { return }
        let inset = row.lastItem.flatMap { sourceInsets[$0] } ?? 0
        var slack = (sourceMaxX - inset) - (back.maxX + leadMin + last.maxX - next.minX)
        let start = sourceLevel
        while slack < -0.5, sourceLevel < 2 {
            sourceLevel += 1
            guard let width = freed[Step(.source, sourceLevel, in: .source)] else { break }
            slack += width
        }
        if sourceLevel == start {
            while sourceLevel > 0, let width = freed[Step(.source, sourceLevel, in: .source)], slack >= width + 0.5 {
                slack -= width
                sourceLevel -= 1
            }
        }
        if sourceLevel != start {
            pending[.source] = Pending(step: nil, folding: sourceLevel > start, before: row.set, expected: [],
                                       width: 0)
        }
    }

    // MARK: Measuring

    private func measure() {
        measureScheduled = false
        // A divider move reaches the toolbar in a later layout pass, and a probe that
        // only moves reports nothing: lay out now, outside any pass, and read that.
        var laidOut = Set<ObjectIdentifier>()
        for window in probes.values.compactMap(\.view?.window) + columns.values.compactMap(\.view?.window)
        where laidOut.insert(ObjectIdentifier(window)).inserted {
            window.layoutIfNeeded()
        }
        guard let pdfShown, let source = columns[.source]?.view.flatMap(Self.screenRect) else { return }
        let frames = frames()
        if pdfShown {
            guard let pdf = columns[.pdf]?.view.flatMap(Self.screenRect), pdf.width > 0 else { return }
            let pdfRow = Row(Self.pdfItems, frames)
            learnPDFInsets(pdfRow, pdf)
            if let slack = pdfSlack(pdfRow, pdf) { decide(.pdf, pdfRow, slack) }
            let sourceRow = Row(Self.sourceItems, frames)
            if let slack = sourceSlack(sourceRow, source, pdfRow, pdf) { decide(.source, sourceRow, slack) }
        } else {
            let row = Row(Set(Item.allCases), frames)
            if let gap = row.spacerGap { decide(.combined, row, gap - spacerFloor(row) + leadRoom(row, overflowing: false)) }
        }
        publish()
    }

    /// Each placed item's frame in screen space: in full screen the toolbar is in a window of its own.
    private func frames() -> [Item: CGRect] {
        probes.compactMapValues { box in
            guard let view = box.view, !view.isHiddenOrHasHiddenAncestor, !view.bounds.isEmpty else { return nil }
            return Self.screenRect(of: view, view.bounds)
        }
    }

    /// A column's visible part: the content column runs on under the sidebar.
    private static func screenRect(_ column: NSView) -> CGRect? {
        screenRect(of: column, column.safeAreaRect)
    }

    private static func screenRect(of view: NSView, _ rect: CGRect) -> CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    /// One section's items in order.
    private struct Row {
        let set: Set<Item>
        let frames: [CGRect]
        let trailing: [CGRect]
        /// The last item before the flexible spacer.
        let lastLeading: CGRect?

        let back: CGRect?
        /// The first item after Back and the title.
        let afterBack: CGRect?
        let firstItem: Item?
        let lastItem: Item?

        init(_ members: Set<Item>, _ all: [Item: CGRect]) {
            let placed = all.filter { members.contains($0.key) }
            set = Set(placed.keys)
            firstItem = placed.min { $0.value.minX < $1.value.minX }?.key
            lastItem = placed.max { $0.value.minX < $1.value.minX }?.key
            back = placed[.back]
            afterBack = back.flatMap { back in
                placed.filter { $0.key != .back && $0.value.minX >= back.maxX }.values.min { $0.minX < $1.minX }
            }
            frames = placed.values.sorted { $0.minX < $1.minX }
            trailing = placed.filter { ToolbarFit.trailingGroup.contains($0.key) }.values.sorted { $0.minX < $1.minX }
            let leadingEdge = trailing.first?.minX
            lastLeading = leadingEdge.flatMap { edge in
                placed.filter { !ToolbarFit.trailingGroup.contains($0.key) && $0.value.maxX <= edge + 0.5 }
                    .values.max { $0.maxX < $1.maxX }
            }
        }

        var first: CGRect? { frames.first }
        var last: CGRect? { frames.last }

        var spacerGap: CGFloat? {
            guard let lastLeading, let next = trailing.first else { return nil }
            return next.minX - lastLeading.maxX
        }

        var smallestTrailingGap: CGFloat? {
            zip(trailing, trailing.dropFirst()).map { $1.minX - $0.maxX }.min()
        }

        /// The room the items need, the spacer and the title's gap at their least.
        func required(spacer: CGFloat, lead: CGFloat?) -> CGFloat {
            guard let first, let last else { return 0 }
            var width = last.maxX - first.minX
            if let gap = spacerGap { width += spacer - gap }
            if let back, let afterBack, let lead { width += lead - (afterBack.minX - back.maxX) }
            return width
        }

        /// From an item to the next one's start: at least what removing it frees.
        func room(from item: CGRect) -> CGFloat {
            frames.first { $0.minX > item.minX + 0.5 }.map { $0.minX - item.minX } ?? item.width
        }
    }

    private func spacerFloor(_ row: Row) -> CGFloat { spacerMin ?? row.smallestTrailingGap ?? 0 }

    /// The room in the gap after the title. Overflowing, the gap is at its least.
    private func leadRoom(_ row: Row, overflowing: Bool) -> CGFloat {
        guard let back = row.back, let next = row.afterBack else { return 0 }
        let lead = next.minX - back.maxX
        leadMin = min(leadMin ?? lead, lead)
        if overflowing { leadExact = true }
        // Until an overflow shows the least, the least seen: never room that isn't there.
        return lead - (leadMin ?? lead)
    }

    /// Learns the PDF section's leading inset while its spacer has clear room, and
    /// the spacer's minimum while the section is pushed left past that inset.
    private func learnPDFInsets(_ row: Row, _ pdf: CGRect) {
        guard let gap = row.spacerGap, let first = row.first, let item = row.firstItem else { return }
        let inset = first.minX - pdf.minX
        // The least seen: a source running over pushes the section right.
        if gap > (row.smallestTrailingGap ?? 0) + 1, inset >= 0 { pdfInsets[item] = min(pdfInsets[item] ?? inset, inset) }
        if let known = pdfInsets[item], pdf.minX + known - first.minX > 0.5 {
            spacerMin = min(spacerMin ?? gap, gap)
        }
    }

    private func pdfInset(_ row: Row) -> CGFloat? { row.firstItem.flatMap { pdfInsets[$0] } }

    private func pdfSlack(_ row: Row, _ pdf: CGRect) -> CGFloat? {
        let inset = pdfInset(row) ?? row.smallestTrailingGap ?? 0
        if let gap = row.spacerGap, let first = row.first {
            let pushed = max(0, pdf.minX + inset - first.minX)
            return gap - spacerFloor(row) - pushed
        }
        return row.trailing.first.map { $0.minX - (pdf.minX + inset) }
    }

    private func sourceSlack(_ row: Row, _ source: CGRect, _ pdfRow: Row, _ pdf: CGRect) -> CGFloat? {
        guard let last = row.last, let lastItem = row.lastItem else { return nil }
        // The source running over pushes the PDF's leading items right; until their
        // inset is known, only tools past the divider show it.
        var over = max(0, last.maxX - source.maxX)
        if pdfRow.spacerGap != nil, let firstPDF = pdfRow.first, let inset = pdfInset(pdfRow) {
            over = (firstPDF.minX - pdf.minX) - inset
        }
        if over > 0.5 {
            sourceInsets[lastItem] = source.maxX + over - last.maxX
            _ = leadRoom(row, overflowing: true)
            return -over
        }
        let inset = sourceInsets[lastItem] ?? pdfInset(pdfRow) ?? pdfRow.smallestTrailingGap ?? 0
        return (source.maxX - last.maxX) - inset + leadRoom(row, overflowing: false)
    }

    // MARK: Deciding

    private func level(_ column: Column) -> Int { column == .source ? sourceLevel : pdfLevel }

    private func setLevel(_ column: Column, _ level: Int) {
        if column == .source { sourceLevel = level } else { pdfLevel = level }
    }

    /// The PDF's tools fold before the source's; they come back in reverse.
    private func nextFold(_ section: Section) -> Column? {
        switch section {
        case .source: sourceLevel < 2 ? .source : nil
        case .pdf: pdfLevel < 2 ? .pdf : nil
        case .combined: pdfLevel < 2 ? .pdf : sourceLevel < 2 ? .source : nil
        }
    }

    private func nextUnfold(_ section: Section) -> Column? {
        switch section {
        case .source: sourceLevel > 0 ? .source : nil
        case .pdf: pdfLevel > 0 ? .pdf : nil
        // Zoom is never in the combined section.
        case .combined: sourceLevel > 0 ? .source : pdfLevel > 1 ? .pdf : nil
        }
    }

    /// The item a step to `level` removes, and the one it puts in its place.
    private static func change(_ column: Column, to level: Int) -> (removed: Item, added: Item?) {
        switch (column, level) {
        case (.source, 1): (.sectionLevelPopUp, .sectionLevelIcon)
        case (.source, _): (.sectionLevelIcon, nil)
        case (.pdf, 1): (.zoom, nil)
        case (.pdf, _): (.share, nil)
        }
    }

    private func decide(_ section: Section, _ row: Row, _ slack: CGFloat) {
        let spacer = spacerFloor(row)
        if let waiting = pending[section], !settle(waiting, section, row, spacer) { return }
        #if DEBUG
        checkMinimum(section, row, slack)
        #endif
        if slack < -0.5 {
            while let column = nextFold(section) {
                let level = level(column) + 1
                setLevel(column, level)
                let step = Step(column, level, in: section)
                let (removed, added) = Self.change(column, to: level)
                guard row.set.contains(removed), let frame = frameOf(removed) else {
                    // Not in the toolbar: nothing moves, so on to the next step.
                    freed[step] = 0
                    continue
                }
                // Until the toolbar shows the step: the room to the next item, at least what it frees.
                if freed[step] == nil { freed[step] = row.room(from: frame) }
                pending[section] = Pending(step: step, folding: true, before: row.set,
                                           expected: row.set.subtracting([removed]).union(added.map { [$0] } ?? []),
                                           width: row.required(spacer: spacer, lead: leadMin))
                return
            }
        } else {
            while let column = nextUnfold(section) {
                let level = level(column)
                let step = Step(column, level, in: section)
                // Unknown until a fold or unfold shows it: tried, and folded again if it doesn't fit.
                let width = freed[step]
                guard slack >= (width ?? 0) + 0.5 else { return }
                setLevel(column, level - 1)
                guard width != 0 else { continue }
                let (removed, added) = Self.change(column, to: level)
                pending[section] = Pending(step: step, folding: false, before: row.set,
                                           expected: row.set.subtracting(added.map { [$0] } ?? []).union([removed]),
                                           width: row.required(spacer: spacer, lead: leadMin))
                return
            }
        }
    }

    private func frameOf(_ item: Item) -> CGRect? {
        probes[item]?.view.flatMap { Self.screenRect(of: $0, $0.bounds) }
    }

    /// Whether to decide on: once the toolbar shows the step, or a second measure
    /// shows it won't (the item was taken out with Customize Toolbar).
    private func settle(_ waiting: Pending, _ section: Section, _ row: Row, _ spacer: CGFloat) -> Bool {
        if row.set == waiting.before {
            guard waiting.measures >= 1 else {
                pending[section]?.measures += 1
                return false
            }
            pending[section] = nil
            return true
        }
        pending[section] = nil
        if let step = waiting.step, row.set == waiting.expected {
            let now = row.required(spacer: spacer, lead: leadMin)
            freed[step] = max(0, waiting.folding ? waiting.width - now : now - waiting.width)
        }
        return true
    }

    #if DEBUG
    /// A section of default items that doesn't fit fully folded means a column minimum is too small.
    /// Over two measures: a transient layout can run over for a pass.
    private func checkMinimum(_ section: Section, _ row: Row, _ slack: CGFloat) {
        guard nextFold(section) == nil, slack < -0.5, row.set.isDisjoint(with: Self.nonDefault) else {
            overfull[section] = 0
            return
        }
        overfull[section, default: 0] += 1
        if overfull[section, default: 0] >= 2 {
            assertionFailure("ColumnMetrics minimum too small for the \(section == .pdf ? "PDF" : "source") toolbar")
        }
    }
    #endif

    private func publish() {
        let style: SectionLevelStyle = switch sourceLevel {
        case 0: .popUp
        case 1: .icon
        default: .hidden
        }
        if sectionLevelStyle != style { sectionLevelStyle = style }
        if showsZoom != (pdfLevel < 1) { showsZoom = pdfLevel < 1 }
        if showsShare != (pdfLevel < 2) { showsShare = pdfLevel < 2 }
    }
}

/// Reports its toolbar item's frame to `ToolbarFit`. AppKit: SwiftUI coordinate
/// spaces stop at each toolbar item's own hosting view.
struct ToolbarProbe: NSViewRepresentable {
    let item: ToolbarFit.Item
    let fit: ToolbarFit

    final class ProbeView: NSView {
        var item: ToolbarFit.Item?
        weak var fit: ToolbarFit?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit?.setNeedsMeasure()
        }

        func report() {
            guard let item, let fit else { return }
            if window != nil { fit.register(self, as: item) } else { fit.unregister(self, as: item) }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.item = item
        view.fit = fit
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        guard view.item != item || view.fit !== fit else { return }
        if let old = view.item { view.fit?.unregister(view, as: old) }
        view.item = item
        view.fit = fit
        view.report()
    }
}

/// Reports its split column's view to `ToolbarFit`, and each divider move. AppKit:
/// SwiftUI's column geometry passes through widths the column never has (27.2).
struct ColumnReader: NSViewRepresentable {
    let column: ToolbarFit.Column
    let fit: ToolbarFit

    final class ReaderView: NSView {
        var column = ToolbarFit.Column.source
        weak var fit: ToolbarFit?
        /// Held weakly: the source column holds the editor's web view, whose page shows in one view only.
        private weak var columnView: NSView?
        private var resizes: NotificationCenter.ObservationToken?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            if !attach() {
                // Not yet in its column's controller: once this pass is done.
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.window != nil, self.columnView == nil, !self.attach() else { return }
                        assertionFailure("ColumnReader's NSSplitViewItem not found")
                    }
                }
            }
        }

        private func attach() -> Bool {
            guard let fit, let item = splitViewItem,
                  let split = item.viewController.parent as? NSSplitViewController else { return false }
            let view = item.viewController.view
            columnView = view
            fit.register(view, as: column, collapsed: item.isCollapsed)
            resizes = NotificationCenter.default.addObserver(of: split.splitView, for: .didResizeSubviews) {
                [weak fit] _ in fit?.setNeedsMeasure()
            }
            return true
        }

        private func detach() {
            if let resizes { NotificationCenter.default.removeObserver(resizes) }
            resizes = nil
            if let columnView { fit?.unregister(columnView, as: column) }
            columnView = nil
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.column = column
        view.fit = fit
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}
}

extension NSView {
    /// The split item whose view controller holds this view; nil until it's in one.
    var splitViewItem: NSSplitViewItem? {
        let controller = sequence(first: self as NSResponder, next: \.nextResponder)
            .lazy.compactMap { $0 as? NSViewController }
            .first { $0.parent is NSSplitViewController }
        guard let controller, let split = controller.parent as? NSSplitViewController else { return nil }
        return split.splitViewItem(for: controller)
    }
}

/// File › New File… and New Folder…: a name, and the folder to make it in.
private struct NewEntrySheet: View {
    let project: ProjectModel
    let directory: Bool
    @State private var name: String
    @State private var folder: String
    @FocusState private var nameFocused: Bool

    init(project: ProjectModel, directory: Bool) {
        self.project = project
        self.directory = directory
        _name = State(initialValue: directory ? "untitled folder" : "untitled.tex")
        _folder = State(initialValue: (project.openPath.map { ($0 as NSString).deletingLastPathComponent }) ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: directory ? "New Folder" : "New File", action: "Create",
                    enabled: !trimmed.isEmpty && !trimmed.hasPrefix("/")) {
            let path = folder.isEmpty ? trimmed : "\(folder)/\(trimmed)"
            Task { await project.createEntry(path, directory: directory) }
        } fields: {
            TextField("Name", text: $name)
                .focused($nameFocused)
            Picker("Where", selection: $folder) {
                Label(project.id, systemImage: "folder").tag("")
                ForEach(project.tree.flattened.filter(\.isDirectory).map(\.path), id: \.self) { path in
                    Label(path, systemImage: "folder").tag(path)
                }
            }
        }
        .defaultFocus($nameFocused, true)
    }
}

/// Edit › Go to Line…
private struct GoToLineSheet: View {
    let project: ProjectModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var lines: Int? { project.counts?.lines }

    private var line: Int? {
        guard let line = Int(text.trimmingCharacters(in: .whitespaces)), line >= 1 else { return nil }
        return lines.map { min(line, $0) } ?? line
    }

    var body: some View {
        DialogSheet(title: "Go to Line", action: "Go", enabled: line != nil) {
            if let line { project.reveal(line: line) }
        } fields: {
            TextField("Line", text: $text, prompt: Text(lines.map { "1–\($0)" } ?? "Line number"))
                .focused($focused)
        }
        .defaultFocus($focused, true)
    }
}

/// Shows and hides the PDF. A document's symbol: the PDF is the source's peer,
/// not a sidebar or an inspector.
struct PDFToggle: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        let title = app.title(.viewTogglePdf, on: project)
        Button(title, systemImage: "doc.richtext") { app.perform(.viewTogglePdf, on: project) }
            .help(title)
    }
}

/// Opens the Project Settings popover; View › Show Project Settings does too.
struct ProjectSettingsButton: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        @Bindable var app = app
        Button("Project Settings", systemImage: "info.circle") { app.showProjectSettings.toggle() }
            .help("Project Settings")
            .popover(isPresented: $app.showProjectSettings, arrowEdge: .bottom) {
                ProjectSettingsView(project: project)
            }
    }
}

/// Edit › Find's items for the pane with the keyboard, else the source's. Its
/// own view, so a focus change redraws it alone.
private struct FindMenuTarget: View {
    let project: ProjectModel
    @FocusedValue(\.find) private var find

    var body: some View {
        FindMenuResponder(find: find ?? project.findAction)
    }
}

/// The project's build settings, then facts about the open file and the build.
struct ProjectSettingsView: View {
    @Bindable var project: ProjectModel

    /// Room for the pop-ups; the toggles' descriptions wrap.
    private static let width: CGFloat = 320

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: BarMetrics.groupSpacing,
             verticalSpacing: BarMetrics.groupSpacing) {
            header("Project")
            let texFiles = project.tree.flattened.filter { !$0.isDirectory && $0.path.hasSuffix(".tex") }.map(\.path)
            pickerRow("Main File", project.settings?.mainFile ?? "", texFiles.map { ($0, $0) }, set: project.setMainFile)
            pickerRow("Engine", project.settings?.engine ?? "", texEngines, set: project.setEngine)
            toggleRow("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.",
                      project.settings?.shellEscape ?? false, set: project.setShellEscape)
            toggleRow("Stop on First Error", "Ends the build at its first error, rather than showing them all.",
                      project.settings?.stopOnFirstError ?? false, set: project.setStopOnFirstError)
            if let path = project.openPath {
                separator
                header("Document")
                row("Name", (path as NSString).lastPathComponent)
                row("Folder", folder(of: path))
                if let counts = project.counts {
                    row("Words", counts.words.formatted())
                    row("Lines", counts.lines.formatted())
                }
                if !project.outline.isEmpty {
                    row("Sections", project.outline.count.formatted())
                }
            }
            separator
            header("Build")
            if let result = project.result {
                row("Last Build", result.stopped ? "Stopped" : result.ok ? "Succeeded" : "Failed")
                row("Duration", result.durationText)
                row("Errors", project.errorCount.formatted())
                row("Warnings", project.warningCount.formatted())
            } else {
                row("Last Build", project.pdfVersion > 0 ? "None Yet" : "None")
            }
            if let freshness = project.pdfFreshness {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label(freshness.title, systemImage: freshness.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Settings arrive from the core after the popover opens.
        .disabled(project.settings == nil)
        .monospacedDigit()
        .padding()
        .frame(width: Self.width, alignment: .leading)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Typography.groupTitle)
            .accessibilityAddTraits(.isHeader)
            .gridCellColumns(2)
    }

    private var separator: some View {
        Divider().gridCellColumns(2).padding(.vertical, BarMetrics.spacing)
    }

    /// Read out with its value or control, not as an element of its own.
    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
    }

    private func pickerRow(_ title: String, _ value: String, _ options: [(String, String)],
                           set: @escaping (String) async -> Void) -> some View {
        GridRow {
            label(title)
            Picker(title, selection: Binding(get: { value }, set: { new in Task { await set(new) } })) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func toggleRow(_ title: String, _ detail: String, _ isOn: Bool,
                           set: @escaping (Bool) async -> Void) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await set(on) } })) {
                Text(title)
                Text(detail)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            label(name)
            Text(value)
                .textSelection(.enabled)
                .accessibilityLabel(name)
                .accessibilityValue(value)
        }
    }

    private func folder(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? project.id : dir
    }
}
