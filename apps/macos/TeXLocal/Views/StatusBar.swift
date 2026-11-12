import AppKit
import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 36
}

/// Xcode's spacing between the bar's texts: 14 pt to the first, 16 between items and 9 before the divider.
private enum Spacing {
    static let lead: CGFloat = 14
    static let items: CGFloat = 16
    static let divider: CGFloat = 9
}

private struct BarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

private extension LabelStyle where Self == BarLabelStyle {
    static var bar: BarLabelStyle { BarLabelStyle() }
}

private struct BarButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Content(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }

    private struct Content: View {
        let label: Configuration.Label
        let pressed: Bool
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            label.foregroundStyle(color)
                .padding(.horizontal, Spacing.items / 2)
                .frame(minHeight: 20)
                .contentShape(.rect)
                .onHover { hovered = $0 }
        }

        private var color: Color {
            if !enabled { return Color(nsColor: .disabledControlTextColor) }
            if selected { return .accentColor }
            return hovered || pressed ? .primary : .secondary
        }
    }
}

/// The bar beneath the source and PDF, showing the build status, caret position and current page.
struct StatusBar: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full).labelStyle(.bar)
            content(.symbols).labelStyle(.iconOnly)
            content(.short).labelStyle(.iconOnly)
        }
        .font(.subheadline)
        .controlSize(.small)
        .lineLimit(1)
        .monospacedDigit()
        .buttonStyle(BarButtonStyle())
        .padding(.leading, Spacing.lead - Spacing.items / 2)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .frame(height: BarMetrics.height)
        .pointerStyle(.default)
        .safeAreaInset(edge: .top, spacing: 0) { Divider() }
        .contextMenu { Button(window.title(.viewToggleWordCount, on: project)) { window.perform(.viewToggleWordCount, on: project) } }
    }

    fileprivate enum Detail { case full, symbols, short }

    private func content(_ detail: Detail) -> some View {
        HStack(spacing: 0) {
            BuildStatus(project: project, detail: detail)
            LiveStatus(project: project)
            SaveStatus(project: project)
            if let notice = project.notices.current { Text(notice).foregroundStyle(.secondary).barText() }
            CaretPlace(project: project, detail: detail)
            WordCount(project: project, detail: detail)
            Spacer(minLength: 0)
            PagePlace(project: project, detail: detail)
            if PagePlace.shows(project, window) { Divider().frame(height: 12).padding(.leading, Spacing.divider - Spacing.items / 2) }
            PanelToggle(project: project)
        }
    }
}

private struct BuildStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: ProjectModel
    let detail: StatusBar.Detail

    var body: some View {
        if state != nil || !project.issues.isEmpty {
            Button { project.showNavigator(.issues) } label: {
                label.fixedSize(horizontal: detail != .short, vertical: true)
            }
            .help("Show issues")
        }
    }

    private var state: (title: LocalizedStringKey, symbol: String?, color: Color?)? {
        if project.compiling { return ("Compiling…", "progress.indicator", .secondary) }
        guard let result = project.result else { return project.hasPDF ? nil : ("No Build Yet", nil, nil) }
        if result.stopped { return ("Build Stopped", nil, nil) }
        if result.ok { return ("Build Succeeded · \(result.durationText)", "checkmark.circle.fill", .green) }
        // The count beside it already wears the error's symbol and says how many.
        return ("Build Failed", project.errorCount == 0 ? "exclamationmark.octagon.fill" : nil, nil)
    }

    private var label: some View {
        HStack {
            if let state {
                if let symbol = state.symbol {
                    badge(state.title, symbol, state.color)
                        .symbolEffect(.variableColor.iterative, options: .repeat(.periodic), isActive: project.compiling && !reduceMotion)
                } else {
                    Text(state.title)
                }
            }
            if project.errorCount > 0 {
                badge("\(project.errorCount)", "exclamationmark.octagon.fill", spoken: "^[\(project.errorCount) error](inflect: true)",
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
        .labelStyle(.bar)
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
            }
            .help("\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason); save again")
        }
    }
}

private struct CaretPlace: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel
    let detail: StatusBar.Detail

    static func shows(_ project: ProjectModel, _ window: WindowModel) -> Bool { window.showSource && project.editsText }

    var body: some View {
        if Self.shows(project, window) {
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
            .barText()
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
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill")
            }
            .help("The latest build failed, so this is the last PDF that built")
        } else if project.outdated, !project.livePDF, !window.app.autoCompile {
            Button { window.perform(.compileRun, on: project) } label: {
                Label("PDF Out of Date", systemImage: "arrow.clockwise")
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
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .buttonStyle(BarButtonStyle(selected: project.panel.shown))
        .help(window.title(.viewToggleLogs, on: project))
    }
}

private func place(_ detail: StatusBar.Detail, _ full: LocalizedStringKey, short: String, spoken: LocalizedStringKey) -> some View {
    Group { if detail == .short { Text(verbatim: short) } else { Text(full) } }
    .accessibilityLabel(spoken)
}

private extension View {
    /// Text between the bar's buttons, given the room their labels take.
    func barText() -> some View { padding(.horizontal, Spacing.items / 2) }
}
