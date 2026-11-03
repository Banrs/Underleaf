import SwiftUI

/// A pane's half of the status bar, its bottom split accessory. The project's status leads the first pane shown and the
/// Logs toggle ends the last.
struct StatusBar: View {
    enum Side { case source, pdf }

    @Environment(WindowModel.self) private var window
    let project: ProjectModel
    let side: Side

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full).labelStyle(.titleAndIcon)
            content(.symbols).labelStyle(.iconOnly)
            content(.short).labelStyle(.iconOnly)
        }
        .font(.subheadline).controlSize(.small).lineLimit(1)
        .contentShape(.rect)
        .monospacedDigit()
        .buttonStyle(.borderless)
        .contextMenu { Button(window.title(.viewToggleWordCount, on: project)) { window.perform(.viewToggleWordCount, on: project) } }
    }

    fileprivate enum Detail { case full, symbols, short }

    private func content(_ detail: Detail) -> some View {
        HStack(spacing: 9) {
            if side == .source || !window.showSource {
                BuildStatus(project: project, detail: detail)
                LiveStatus(project: project)
                SaveStatus(project: project)
                if let notice = project.notices.current { Text(notice).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                switch side {
                case .source:
                    CaretPlace(project: project, detail: detail)
                    WordCount(project: project, detail: detail)
                case .pdf:
                    PagePlace(project: project, detail: detail)
                }
            }
            .fixedSize()
            if side == .pdf || !window.showPDF {
                HStack(spacing: 0) {
                    if side == .source ? project.editsText : PagePlace.shows(project, window) { Divider().frame(height: 12) }
                    PanelToggle(project: project)
                }
            }
        }
    }
}

private struct BuildStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: ProjectModel
    let detail: StatusBar.Detail

    var body: some View {
        Button { project.showNavigator(.issues) } label: {
            label.fixedSize(horizontal: detail != .short, vertical: true).hitTarget()
        }
        .help("Show issues")
    }

    /// The build's state, its symbol replacing the last one as it changes, and pulsing while it compiles.
    private var state: (title: LocalizedStringKey, symbol: String?, color: Color?)? {
        if project.compiling { return ("Compiling…", "progress.indicator", .secondary) }
        guard let result = project.result else { return project.hasPDF ? nil : ("No Build Yet", nil, nil) }
        if result.stopped { return ("Build Stopped", nil, nil) }
        if result.ok { return ("Build Succeeded · \(result.durationText)", "checkmark.circle.fill", .green) }
        return (project.errorCount == 0 ? "Build Failed" : "Build Failed · ^[\(project.errorCount) Error](inflect: true)",
                "xmark.octagon.fill", nil)
    }

    private var label: some View {
        HStack {
            if let state {
                if let symbol = state.symbol {
                    badge(state.title, symbol, state.color)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: project.compiling && !reduceMotion)
                } else {
                    Text(state.title)
                }
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill", spoken: "^[\(project.errorCount) error](inflect: true)",
                      count: project.errorCount)
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill",
                      spoken: "^[\(project.warningCount) warning](inflect: true)", count: project.warningCount)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: project.compiling)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: [project.errorCount, project.warningCount])
    }

    private func badge(_ title: LocalizedStringKey, _ systemImage: String, _ color: Color? = nil,
                       spoken: LocalizedStringKey? = nil, count: Int? = nil) -> some View {
        Label {
            Text(title)
                .contentTransition(count.map { .numericText(value: Double($0)) } ?? .opacity)
                .accessibilityLabel(Text(spoken ?? title))
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(color == nil ? .multicolor : nil)
                .foregroundStyle(color ?? .primary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct LiveStatus: View {
    let project: ProjectModel

    var body: some View {
        if project.texpresso.phase != .stopped || project.texpresso.needsAttention {
            let title = project.liveEngine
            Button { project.panel.show(.texpresso) } label: {
                Label {
                    if let title {
                        Text("\(Text(project.texpresso.title)) \(Text("· \(title)").foregroundStyle(.secondary))")
                    } else {
                        Text(project.texpresso.title)
                    }
                } icon: {
                    Image(systemName: project.texpresso.needsAttention ? "exclamationmark.triangle" : "bolt")
                }
                .hitTarget()
            }
            .help(title.map { "Live Preview typesets with \($0), so line breaks may differ from the compiled PDF; show the Live Preview log" }
                  ?? "Show the Live Preview log")
        }
    }
}

private struct SaveStatus: View {
    let project: ProjectModel

    var body: some View {
        if let reason = project.saveFailure {
            Button { Task { await project.save() } } label: {
                Label("Not Saved", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .hitTarget()
            }
            .help("\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason); save again")
        }
    }
}

private struct CaretPlace: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel
    let detail: StatusBar.Detail

    var body: some View {
        if window.showSource, project.editsText {
            Button { window.perform(.editGotoLine, on: project) } label: {
                place(detail, "Line: \(String(project.cursorLine))  Col: \(String(project.shownColumn))",
                      short: "\(project.cursorLine):\(project.shownColumn)",
                      spoken: "Line \(project.cursorLine), Column \(project.shownColumn)")
            }
            .help("Go to a line")
        }
    }
}

private struct WordCount: View {
    @Environment(WindowModel.self) private var window
    @Environment(WorkspaceViews.self) private var views
    let project: ProjectModel
    let detail: StatusBar.Detail
    @State private var selectedWords: Int?

    var body: some View {
        if detail == .full, window.showSource, project.editsText, window.app.showWordCount, let words = project.words {
            Group {
                if let selectedWords {
                    Text("\(selectedWords) of ^[\(words) word](inflect: true)")
                } else {
                    Text("^[\(words) word](inflect: true)")
                }
            }
            .foregroundStyle(.secondary)
            .layoutPriority(-1)
            .task(id: views.changes) {
                let selection = views.selection
                guard selection.length > 0 else { return selectedWords = nil }
                guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
                selectedWords = views.words(in: selection)
            }
        }
    }
}

private struct PagePlace: View {
    @Environment(WindowModel.self) private var window
    @Environment(WorkspaceViews.self) private var views
    let project: ProjectModel
    let detail: StatusBar.Detail

    static func shows(_ project: ProjectModel, _ window: WindowModel) -> Bool { window.showPDF && project.hasPDF }

    var body: some View {
        if Self.shows(project, window) {
            freshness
            Button { window.perform(.pdfGotoPage, on: project) } label: {
                let (page, count) = (views.pdf.page, views.pdf.pageCount)
                place(detail, "Page \(String(page)) of \(String(count))", short: "\(page)/\(count)", spoken: "Page \(page) of \(count)")
            }
            .help("Go to a page")
        }
    }

    @ViewBuilder private var freshness: some View {
        if project.showsLastSuccessfulBuild {
            Button { project.showNavigator(.issues) } label: {
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill").hitTarget()
            }
            .help("The latest build failed, so this is the last PDF that built")
        } else if project.outdated, !project.livePDF, !window.app.autoCompile {
            Button { window.perform(.compileRun, on: project) } label: {
                Label("PDF Out of Date", systemImage: "arrow.clockwise").hitTarget()
            }
            .help("The PDF is older than the source; compile to refresh it")
            .disabled(!window.app.isEnabled(.compileRun, on: project))
        }
    }
}

private struct PanelToggle: View {
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let project: ProjectModel

    var body: some View {
        Toggle(isOn: Bindable(project.panel).shown) {
            Label("Logs", systemImage: differentiateWithoutColor && !project.panel.shown
                  ? "square" : "inset.filled.bottomthird.square")
                .font(.body)
                .hitTarget()
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .help(window.title(.viewToggleLogs, on: project))
    }
}

private func place(_ detail: StatusBar.Detail, _ full: LocalizedStringKey, short: String, spoken: LocalizedStringKey) -> some View {
    Group { if detail == .short { Text(verbatim: short) } else { Text(full) } }
    .accessibilityLabel(spoken)
    .hitTarget()
}

extension View {
    func barRow() -> some View {
        font(.subheadline).controlSize(.small).lineLimit(1).frame(minHeight: 20).padding(.horizontal, 8).padding(.vertical, 8)
    }

    /// A bar's top edge, one device pixel as AppKit draws the edges of the toolbar and its scroll pockets (measured in
    /// TextEdit), rather than the 1 pt a split view draws between panes. The status bar has none of its own: its panes'
    /// hard pockets draw it, and one over it made 1.5 pt over the editor.
    func barEdge() -> some View { overlay(alignment: .top) { Hairline() } }

    /// The HIG's least hit region on macOS, 20 by 20 pt.
    fileprivate func hitTarget() -> some View { frame(minWidth: 20, minHeight: 20).contentShape(.rect) }
}

private struct Hairline: View {
    @Environment(\.displayScale) private var scale

    var body: some View { Rectangle().fill(.separator).frame(height: 1 / scale) }
}
