import SwiftUI

/// The build panel's tabs.
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

/// The build panel below the editors: the build's issues, or its whole log
/// (web/src/logs.js `renderLogs`). The status bar's toggle and View › Hide
/// Build Panel close it, as Xcode's debug area has no close button of its own.
struct PanelView: View {
    @Environment(AppModel.self) private var app
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
            Picker("Build Panel", selection: $project.panelTab) {
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
        }
        .labelStyle(.iconOnly)
    }

    /// The build's outcome, worded as the status bar words it; only the
    /// badges carry colour.
    @ViewBuilder
    private var summary: some View {
        if let result = project.result {
            HStack(spacing: 8) {
                if result.ok {
                    badge("Compiled in \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    badge("Build Failed", "xmark.octagon.fill", .red)
                }
                // The failure's badge already stands for the errors.
                if project.errorCount > 0 {
                    Text(count(project.errorCount, "Error"))
                }
                if project.warningCount > 0 {
                    badge(count(project.warningCount, "Warning"), "exclamationmark.triangle.fill", .orange)
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
            Text("Not Compiled").foregroundStyle(.secondary)
        }
    }

    private func badge(_ title: String, _ systemImage: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
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
            ContentUnavailableView {
                Label("Not Compiled Yet", systemImage: "hammer")
            } description: {
                Text("Compile to see errors and warnings here.")
            } actions: {
                Button("Compile") { app.perform(.compileRun) }
                    .disabled(!app.isEnabled(.compileRun))
            }
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

/// An error or warning; choosing it opens its line — in the main file when
/// the log names none, as the web's does.
private struct IssueRow: View {
    let item: LogItem
    let project: ProjectModel

    var body: some View {
        Button {
            if let file { Task { await project.open(file, line: item.line) } }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.message).lineLimit(3).textSelection(.enabled)
                    if let file = item.file {
                        Text(item.line.map { "\(file):\($0)" } ?? file)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(item.isError ? .red : .orange)
            }
        }
        .buttonStyle(.plain)
        .disabled(file == nil)
    }

    private var file: String? {
        item.file ?? (item.line == nil ? nil : project.settings?.mainFile)
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
