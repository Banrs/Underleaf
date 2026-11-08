import AppKit
import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 36
    static let target: CGFloat = 20
    static let inset: CGFloat = 8
    static let symbolWidth: CGFloat = 30

    /// The bar's top edge uses the thin split divider's colour and thickness, which follow Increase Contrast, so it
    /// matches the dividers it meets.
    static let edge: (color: NSColor, thickness: CGFloat) = {
        let split = NSSplitView()
        split.dividerStyle = .thin
        return (split.dividerColor, split.dividerThickness)
    }()
}

/// Xcode's spacing between texts: 14 pt to the first item, 16 between items and 9 before the divider; an icon 4 pt from
/// its text, as in an AppKit button. Each item reaches `overhang` past its text either side, as far as the accessory bar
/// style's hover capsule reaches past a small AppKit label, and the items are spaced by what's left.
private enum Spacing {
    static let lead: CGFloat = 14
    static let items: CGFloat = 16
    static let group: CGFloat = 8
    static let divider: CGFloat = 9
    static let icon: CGFloat = 4
    static let overhang: CGFloat = 5
}

private struct BarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.icon) {
            configuration.icon
            configuration.title
        }
    }
}

private extension LabelStyle where Self == BarLabelStyle {
    static var bar: BarLabelStyle { BarLabelStyle() }
}

struct StatusBar: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full).labelStyle(.bar)
            content(.symbols).labelStyle(.iconOnly)
            content(.short).labelStyle(.iconOnly)
        }
        .barRow()
        .padding(.top, BarMetrics.edge.thickness)
        .barEdge()
        .contentShape(.rect)
        .monospacedDigit()
        .buttonStyle(.accessoryBar)
        .buttonBorderShape(.capsule)
        .contextMenu { Button(window.title(.viewToggleWordCount, on: project)) { window.perform(.viewToggleWordCount, on: project) } }
    }

    fileprivate enum Detail { case full, symbols, short }

    private func content(_ detail: Detail) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Spacing.items - 2 * Spacing.overhang) {
                BuildStatus(project: project, detail: detail)
                LiveStatus(project: project)
                SaveStatus(project: project)
                if let notice = project.notices.current { Text(notice).foregroundStyle(.secondary).barText() }
            }
            Spacer(minLength: Spacing.items - 2 * Spacing.overhang)
            HStack(spacing: Spacing.items - 2 * Spacing.overhang) {
                CaretPlace(project: project, detail: detail)
                WordCount(project: project, detail: detail)
                PagePlace(project: project, detail: detail)
            }
            .fixedSize()
            if CaretPlace.shows(project, window) || PagePlace.shows(project, window) {
                Divider().frame(height: 12).padding(.leading, Spacing.divider - Spacing.overhang)
            }
            PanelToggle(project: project)
        }
        .padding(.leading, Spacing.lead - Spacing.overhang - BarMetrics.inset)
    }
}

private struct BuildStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: ProjectModel
    let detail: StatusBar.Detail

    var body: some View {
        Button { project.showNavigator(.issues) } label: {
            label.fixedSize(horizontal: detail != .short, vertical: true).barItem()
        }
        .help("Show issues")
    }

    private var state: (title: LocalizedStringKey, symbol: String?, color: Color?)? {
        if project.compiling { return ("Compiling…", "progress.indicator", .secondary) }
        guard let result = project.result else { return project.hasPDF ? nil : ("No Build Yet", nil, nil) }
        if result.stopped { return ("Build Stopped", nil, nil) }
        if result.ok { return ("Build Succeeded · \(result.durationText)", "checkmark.circle.fill", .green) }
        return (project.errorCount == 0 ? "Build Failed" : "Build Failed · ^[\(project.errorCount) Error](inflect: true)",
                "xmark.octagon.fill", nil)
    }

    private var label: some View {
        HStack(spacing: Spacing.group) {
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
                .barItem()
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
                    .barItem()
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
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill").barItem()
            }
            .help("The latest build failed, so this is the last PDF that built")
        } else if project.outdated, !project.livePDF, !window.app.autoCompile {
            Button { window.perform(.compileRun, on: project) } label: {
                Label("PDF Out of Date", systemImage: "arrow.clockwise").barItem()
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
        .buttonStyle(.borderless)
        .help(window.title(.viewToggleLogs, on: project))
    }
}

private func place(_ detail: StatusBar.Detail, _ full: LocalizedStringKey, short: String, spoken: LocalizedStringKey) -> some View {
    Group { if detail == .short { Text(verbatim: short) } else { Text(full) } }
    .accessibilityLabel(spoken)
    .barItem()
}

extension View {
    func barRow() -> some View {
        font(.subheadline).controlSize(.small).lineLimit(1)
            .frame(minHeight: BarMetrics.target).padding(.horizontal, BarMetrics.inset).padding(.vertical, 8)
    }

    func barEdge() -> some View { overlay(alignment: .top) { Hairline() } }

    /// A button's label, which SwiftUI's accessory bar style pads 10 pt either side, where AppKit's pads a small one 5.
    fileprivate func barItem() -> some View { padding(.horizontal, Spacing.overhang - 10) }

    /// Text between the buttons, given the room their capsules take.
    fileprivate func barText() -> some View { padding(.horizontal, Spacing.overhang) }

    fileprivate func hitTarget() -> some View {
        frame(minWidth: BarMetrics.symbolWidth, minHeight: BarMetrics.target).contentShape(.rect)
    }
}

/// The divider colour is translucent, so it's drawn over the window background, as split view dividers are. Over the
/// scroll edge's line it came out a step lighter than the dividers it meets.
private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: BarMetrics.edge.color))
            .background(Color(nsColor: .untintedTextBackground))
            .frame(height: BarMetrics.edge.thickness)
    }
}
