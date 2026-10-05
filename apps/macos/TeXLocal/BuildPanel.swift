import SwiftUI

/// The build panel's tabs, by title.
enum PanelTab: String, CaseIterable {
    case issues = "Issues", log = "Build Log", texpresso = "TeXpresso"
}

@Observable final class BuildPanelState {
    var filter = ""
    var showWarnings = true
}

/// The build panel below the editors: the build's issues, or its whole log.
/// No close button: the status bar's toggle and View › Hide Build Panel close it.
struct BuildPanel: View {
    let project: ProjectModel
    let state: BuildPanelState

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
                    LogTextView(text: project.texpresso.log, title: "TeXpresso Log")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func matches(_ item: LogItem) -> Bool {
        state.filter.isEmpty || item.message.localizedCaseInsensitiveContains(state.filter)
            || (item.file?.localizedCaseInsensitiveContains(state.filter) ?? false)
    }

    /// "No Issues" before any build too: the status bar says whether one has run.
    @ViewBuilder
    private var issues: some View {
        // Enumerate before filtering: duplicate messages keep distinct, stable row IDs.
        let all = (project.result?.errors ?? []) + (state.showWarnings ? project.result?.warnings ?? [] : [])
        let items = all.enumerated().filter { matches($0.element) }
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !state.showWarnings, project.result?.warnings.contains(where: matches) == true {
            ContentUnavailableView {
                Label("Warnings Hidden", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Show Warnings") { state.showWarnings = true }
            }
        } else if !state.filter.isEmpty {
            ContentUnavailableView.search(text: state.filter)
        } else {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder
    private var log: some View {
        if let text = project.result?.log, !text.isEmpty {
            LogTextView(text: text)
        } else {
            ContentUnavailableView("No Log", systemImage: "text.page",
                                   description: Text("Compile to see the log here."))
        }
    }
}

/// Controls on the editors' bottom accessory, above the build panel's opaque content.
/// The log has the text view's own find bar, so only the issues have a filter.
struct BuildPanelHeader: View {
    /// One height in both tabs: Copy Log's bezel is 2 pt taller than Warnings'.
    static let height: CGFloat = 24
    @Bindable var project: ProjectModel
    @Binding var filter: String
    @Binding var showWarnings: Bool

    var body: some View {
        HStack {
            Picker("Build Panel", selection: $project.panelTab) {
                // TeXpresso's only once it has been started: most never use it.
                ForEach(PanelTab.allCases.filter { $0 != .texpresso || project.texpresso.used }, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.tabs)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: 0)
            if project.panelTab == .issues {
                if project.warningCount > 0 {
                    Toggle(isOn: $showWarnings) {
                        Label("Warnings", systemImage: "exclamationmark.triangle")
                    }
                    .toggleStyle(.button)
                    .help(showWarnings ? "Hide Warnings" : "Show Warnings")
                }
                // The regular size, the tabs' 24 points.
                SearchField(text: $filter, prompt: "Filter", symbol: "line.3.horizontal.decrease.circle")
                    .frame(minWidth: 100, maxWidth: 180)
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
        .frame(height: Self.height)
        .lineLimit(1)
        .buttonStyle(.accessoryBar)
        .labelStyle(.iconOnly)
        .padding(.horizontal, ColumnMetrics.barSideInset)
        .padding(.vertical, 9)
        // Clear over the editors, which AppKit's scroll edge blurs; the split's divider is under it.
        .overlay(alignment: .top) { Divider() }
    }
}

/// The errors and warnings. Choosing one shows its line and leaves the keyboard
/// in the list, as the outline does; a double-click or Return goes into the source.
/// Rows are places in the build's issues, so a new build starts with none chosen.
private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel
    @State private var selection: Int?

    var body: some View {
        List(items, id: \.offset, selection: $selection) { IssueRow(item: $0.element) }
        .listStyle(.inset)
        .accessibilityLabel("Issues")
        .scrollContentBackground(.hidden)
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
        .copyable(selection.flatMap(item).map { [$0.message] } ?? [])
        .onChange(of: project.compiling) { selection = nil }
        .onChange(of: selection) { _, id in
            if let item = id.flatMap(item) { open(item, focus: false) }
        }
    }

    private func item(_ id: Int) -> LogItem? {
        items.first { $0.offset == id }?.element
    }

    private func open(_ item: LogItem, focus: Bool = true) {
        if let file = item.file { Task { await project.open(file, line: item.line, focus: focus) } }
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

/// The build log in an NSTextView: a SwiftUI Text lays out megabyte logs whole on every change.
/// It opens at its end, where the error usually is.
struct LogTextView: NSViewRepresentable {
    let text: String
    var title = "Build Log"

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        // Lines the text up with the header's controls, at AppKit's accessory
        // inset; the fragment padding would put it past them.
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.textContainer?.lineFragmentPadding = 0
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                          weight: .regular)
        // A text view has no title of its own for VoiceOver.
        view.setAccessibilityLabel(title)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        updateText(in: scroll)
    }

    func updateText(in scroll: NSScrollView) {
        let view = scroll.documentView as! NSTextView
        guard view.string != text else { return }
        let selections = view.selectedRanges.map(\.rangeValue)
        let origin = scroll.contentView.bounds.origin
        let followsTail = !scroll.isFindBarVisible && selections.allSatisfy { $0.length == 0 }
            && (view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1)
        // Append without invalidating the entire log's layout. A new build or
        // bounded log rollover can replace it; keep reading position in either case.
        let previousLength = (view.string as NSString).length
        if previousLength > 0, text.utf16.starts(with: view.string.utf16) {
            view.textStorage?.replaceCharacters(in: NSRange(location: previousLength, length: 0),
                                                with: (text as NSString).substring(from: previousLength))
        } else {
            view.string = text
        }
        view.didChangeText()
        let length = (text as NSString).length
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
