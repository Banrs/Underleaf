import SwiftUI

/// The panel's tabs.
enum PanelTab: String, CaseIterable, Identifiable {
    case issues, log

    var id: Self { self }

    var title: String {
        switch self {
        case .issues: "Issues"
        case .log: "Build Log"
        }
    }
}

/// The panel below the editors, shown and hidden as VS Code's is: the
/// build's issues, or its whole log (web/src/logs.js `renderLogs`).
struct PanelView: View {
    @Bindable var project: ProjectModel
    @State private var filter = ""
    @State private var showWarnings = true

    var body: some View {
        VStack(spacing: 0) {
            PaneBar { header }
            Divider()
            Group {
                switch project.panelTab {
                case .issues: issues
                case .log: log
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        Group {
            Picker("Panel", selection: $project.panelTab) {
                ForEach(PanelTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            summary
            Spacer(minLength: 8)
            if project.panelTab == .issues {
                Toggle(isOn: $showWarnings) {
                    Label("Warnings", systemImage: "exclamationmark.triangle")
                }
                .toggleStyle(.button)
                .help(showWarnings ? "Hide Warnings" : "Show Warnings")
                .disabled(project.warningCount == 0)
            } else {
                Button("Copy Log", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(project.result?.log ?? "", forType: .string)
                }
                .help("Copy Log")
                .disabled(project.result?.log.isEmpty ?? true)
            }
            SearchField(text: $filter, prompt: "Filter")
                .frame(minWidth: 60, maxWidth: 180)
            Button("Hide Panel", systemImage: "xmark") { project.showLogs = false }
                .help("Hide Panel")
                .layoutPriority(1)
        }
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private var summary: some View {
        if let result = project.result {
            HStack(spacing: 8) {
                if project.errorCount > 0 {
                    Label("\(project.errorCount) \(project.errorCount == 1 ? "error" : "errors")",
                          systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Compiled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if project.warningCount > 0 {
                    Label("\(project.warningCount) \(project.warningCount == 1 ? "warning" : "warnings")",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("\(Double(result.durationMs) / 1000, format: .number.precision(.fractionLength(1))) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
        } else {
            Text("Not compiled yet").foregroundStyle(.secondary)
        }
    }

    private var items: [LogItem] {
        let all = (project.result?.errors ?? []) + (showWarnings ? project.result?.warnings ?? [] : [])
        guard !filter.isEmpty else { return all }
        return all.filter { item in
            item.message.localizedCaseInsensitiveContains(filter)
                || (item.file?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    @ViewBuilder
    private var issues: some View {
        if project.result == nil {
            ContentUnavailableView("Not Compiled Yet", systemImage: "hammer",
                                   description: Text("Compile to see errors and warnings here."))
        } else if items.isEmpty {
            if filter.isEmpty {
                ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
            } else {
                ContentUnavailableView.search(text: filter)
            }
        } else {
            // By position: LaTeX repeats identical warnings, which would
            // share an id built from their contents.
            List(Array(items.enumerated()), id: \.offset) { _, item in IssueRow(item: item, project: project) }
                .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var log: some View {
        if let text = project.result?.log, !text.isEmpty {
            let lines = filter.isEmpty
                ? text
                : text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { $0.localizedCaseInsensitiveContains(filter) }
                    .joined(separator: "\n")
            LogTextView(text: lines, scrollsToEnd: filter.isEmpty)
        } else {
            ContentUnavailableView("No Log", systemImage: "doc.plaintext",
                                   description: Text("Compile to see the log here."))
        }
    }
}

/// The build log in AppKit's text view: native scrolling and selection, the
/// system find bar (⌘F), and fast with the megabyte logs LaTeX writes, which
/// a SwiftUI Text laid out whole on every change.
private struct LogTextView: NSViewRepresentable {
    let text: String
    /// Unfiltered, the log opens at its end, where the error usually is.
    let scrollsToEnd: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.textColor = .labelColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        guard view.string != text else { return }
        view.string = text
        if scrollsToEnd { view.scrollToEndOfDocument(nil) } else { view.scrollToBeginningOfDocument(nil) }
    }
}
