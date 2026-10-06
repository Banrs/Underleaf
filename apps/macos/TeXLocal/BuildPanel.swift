import SwiftUI

/// The build panel's tabs, by title.
enum PanelTab: String, CaseIterable {
    case issues = "Issues", log = "Build Log", texpresso = "TeXpresso"
}

/// The build panel below the editors and their status bar: the build's issues or its whole log,
/// which scroll on beneath `BuildPanelBar` at the panel's foot, as Xcode's console under its bar.
/// On the editors' surface, as Xcode's console is on its editor's. No close button: the status
/// bar's toggle and View › Hide Build Panel close it.
struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        Group {
            switch project.panelTab {
            case .issues: issues
            case .log: log
            case .texpresso:
                if project.texpresso.log.isEmpty {
                    ContentUnavailableView(project.texpresso.title, systemImage: "bolt",
                                           description: Text(project.livePDF ? "The PDF pane shows TeXpresso’s live preview."
                                                             : "TeXpresso shows the document in its own window. Compile to update the PDF here."))
                } else {
                    LogPane(text: project.texpresso.log, title: "TeXpresso Log")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.textSurface)
        // In the panel's own content, not a split-item accessory, so it rides the panel's edge as
        // the panel opens: AppKit shows a bottom accessory only once the pane has its height (27.2).
        .safeAreaBar(edge: .bottom, spacing: 0) { BuildPanelBar(project: project) }
    }

    private func matches(_ item: LogItem) -> Bool {
        project.issueFilter.isEmpty || item.message.localizedCaseInsensitiveContains(project.issueFilter)
            || (item.file?.localizedCaseInsensitiveContains(project.issueFilter) ?? false)
    }

    /// "No Issues" before any build too: the status bar says whether one has run.
    @ViewBuilder
    private var issues: some View {
        // Enumerate before filtering: duplicate messages keep distinct, stable row IDs.
        let items = project.issues.enumerated().filter { (project.showsWarnings || $0.element.isError) && matches($0.element) }
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !project.showsWarnings, project.result?.warnings.contains(where: matches) == true {
            ContentUnavailableView {
                Label("Warnings Hidden", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Show Warnings") { project.showsWarnings = true }
            }
        } else if !project.issueFilter.isEmpty {
            ContentUnavailableView.search(text: project.issueFilter)
        } else {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder
    private var log: some View {
        if let text = project.result?.log, !text.isEmpty {
            LogPane(text: text)
        } else {
            ContentUnavailableView("No Log", systemImage: "text.page",
                                   description: Text("Compile to see the log here."))
        }
    }
}

/// The bar at the panel's foot, as Xcode's console bar: what the panel shows, chosen from a
/// pop-up as Xcode's console chooses its output, then that view's controls. The log has the text
/// view's own find bar, so only the issues have a filter. The panel's content scrolls beneath it
/// (`BuildPanel`), and it paints the panel's surface.
struct BuildPanelBar: View {
    @Bindable var project: ProjectModel

    var body: some View {
        HStack {
            Picker("Show", selection: $project.panelTab) {
                // TeXpresso's only once it has been started: most never use it.
                ForEach(PanelTab.allCases.filter { $0 != .texpresso || project.texpresso.used }, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.menu)
            // Borderless, as Xcode's console's output pop-up.
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: 0)
            if project.panelTab == .issues {
                if project.warningCount > 0 {
                    Toggle(isOn: $project.showsWarnings) {
                        Label("Warnings", systemImage: "exclamationmark.triangle")
                    }
                    .toggleStyle(.button)
                    .help(project.showsWarnings ? "Hide Warnings" : "Show Warnings")
                }
                SearchField(text: $project.issueFilter, prompt: "Filter", symbol: "line.3.horizontal.decrease.circle")
                    .frame(maxWidth: 180)
            } else {
                let text = project.panelTab == .texpresso ? project.texpresso.log : project.result?.log ?? ""
                Button("Copy Log", systemImage: "document.on.document") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help("Copy Log")
                .disabled(text.isEmpty)
            }
        }
        .lineLimit(1)
        .buttonStyle(.accessoryBar)
        .labelStyle(.iconOnly)
        // The status bar's height and edges, whichever view's controls show: one bar in the window.
        .frame(height: StatusBar.height)
        .padding(.leading, 14)
        .padding(.trailing, 16.5)
        .background(.textSurface)
    }
}

/// The errors and warnings. Choosing one shows its line and leaves the keyboard
/// in the list, as the outline does; a double-click or Return goes into the source.
/// Rows are places in the build's issues, and the chosen one the project's, as the menus move it too.
private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel

    var body: some View {
        let selection = Binding { project.chosenIssue } set: { project.chooseIssue($0, focus: false) }
        ScrollViewReader { proxy in
            List(items, id: \.offset, selection: selection) { IssueRow(item: $0.element) }
                .listStyle(.inset)
                .accessibilityLabel("Issues")
                .contextMenu(forSelectionType: Int.self) { rows in
                    if let item = rows.first.flatMap(item) {
                        if item.file != nil {
                            Button(item.line == nil ? "Open File" : "Go to Line") { open(item) }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.message, forType: .string)
                        }
                    }
                } primaryAction: { rows in
                    if let item = rows.first.flatMap(item) { open(item) }
                }
                // Edit › Copy copies the selected issue.
                .copyable(project.chosenIssue.flatMap(item).map { [$0.message] } ?? [])
                // The menus' choice may be out of sight, and the panel closed: a hidden list
                // scrolls by its rows' estimated heights, so again as it comes up.
                .onChange(of: project.chosenIssue) { _, place in
                    if let place { proxy.scrollTo(place) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _ in
                    if let place = project.chosenIssue { proxy.scrollTo(place) }
                }
        }
    }

    private func item(_ id: Int) -> LogItem? {
        items.first { $0.offset == id }?.element
    }

    private func open(_ item: LogItem) {
        if let file = item.file { Task { await project.open(file, line: item.line) } }
    }
}

/// An error or warning: its message, and its location when the log names one.
private struct IssueRow: View {
    let item: LogItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message).lineLimit(3)
                if let location = location(line: ":") {
                    Text(location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message)")
        // Spoken as words: "main.tex, line 12", not "main.tex colon 12".
        .accessibilityValue(location(line: ", line ") ?? "")
    }

    /// The file, and its line after `line`; nil when the log names none.
    private func location(line: String) -> String? {
        item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file }
    }
}

/// The log under the panel's bar: the text view runs on beneath the bar, inset by its height so
/// its last line and its scroller end at the bar's top. The bar's safe area reaches SwiftUI but
/// not an AppKit scroll view, which takes the inset itself.
private struct LogPane: View {
    let text: String
    var title = "Build Log"

    var body: some View {
        GeometryReader { geometry in
            LogTextView(text: text, title: title, bottomInset: geometry.safeAreaInsets.bottom)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// The build log in an NSTextView: a SwiftUI Text lays out megabyte logs whole on every change.
/// It opens at its end, where the error usually is.
struct LogTextView: NSViewRepresentable {
    let text: String
    var title = "Build Log"
    /// The bar over the text view's foot (`LogPane`).
    var bottomInset: CGFloat = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                          weight: .regular)
        // A text view has no title of its own for VoiceOver.
        view.setAccessibilityLabel(title)
        return scroll
    }

    /// The text last shown: an update that leaves the log as it was (a tab or the filter
    /// changing) compares the same storage, without passes over a megabyte log.
    final class Coordinator {
        var shown: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        if scroll.contentInsets.bottom != bottomInset {
            let atEnd = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = bottomInset
            if atEnd { view.scrollToEndOfDocument(nil) }
        }
        guard context.coordinator.shown != text else { return }
        updateText(in: scroll)
        context.coordinator.shown = text
    }

    func updateText(in scroll: NSScrollView) {
        let view = scroll.documentView as! NSTextView
        let shown = view.string
        guard shown != text else { return }
        let selections = view.selectedRanges.map(\.rangeValue)
        let origin = scroll.contentView.bounds.origin
        let followsTail = !scroll.isFindBarVisible && selections.allSatisfy { $0.length == 0 }
            && (shown.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1)
        // Append without invalidating the entire log's layout. A new build or
        // bounded log rollover can replace it; keep reading position in either case.
        let previousLength = (shown as NSString).length, new = text as NSString
        if previousLength > 0, text.utf16.starts(with: shown.utf16) {
            view.textStorage?.replaceCharacters(in: NSRange(location: previousLength, length: 0),
                                                with: new.substring(from: previousLength))
        } else {
            view.string = text
        }
        view.didChangeText()
        let length = new.length
        view.selectedRanges = selections.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        if followsTail {
            view.scrollToEndOfDocument(nil)
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

#Preview("Issues") {
    List {
        IssueRow(item: LogItem(type: "error", file: "chapters/intro.tex", line: 42, message: "Undefined control sequence."))
        IssueRow(item: LogItem(type: "warning", file: "main.tex", line: nil, message: "Citation `knuth84' undefined."))
        IssueRow(item: LogItem(type: "warning", file: nil, line: nil, message: "There were undefined references."))
    }
    .listStyle(.inset)
    .frame(width: 480, height: 200)
}

#Preview("Build log") {
    LogTextView(text: "This is pdfTeX, Version 3.141592653\n(./main.tex\nLaTeX2e <2025-06-01>\n)\nOutput written on main.pdf (4 pages).")
        .frame(width: 480, height: 160)
}
