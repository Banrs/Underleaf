import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 36
    static let target: CGFloat = 20
}

struct StatusBar: View {
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full).labelStyle(.titleAndIcon)
            content(.symbols).labelStyle(.iconOnly)
            content(.short).labelStyle(.iconOnly)
        }
        .barRow(leading: 14, trailing: 16.5)
        .background(.textSurface)
        .contentShape(.rect)
        .monospacedDigit()
        .buttonStyle(.borderless)
        .contextMenu { Button(window.title(.viewToggleWordCount, on: project)) { window.perform(.viewToggleWordCount, on: project) } }
    }

    fileprivate enum Detail { case full, symbols, short }

    private func content(_ detail: Detail) -> some View {
        HStack(spacing: 9) {
            BuildStatus(project: project, detail: detail)
            LiveStatus(project: project)
            SaveStatus(project: project)
            if let notice = project.notices.current { Text(notice).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                CaretPlace(project: project, detail: detail)
                WordCount(project: project, detail: detail)
                PagePlace(project: project, detail: detail)
            }
            .fixedSize()
            if window.showSource && project.editsText || PagePlace.shows(project, window) { Divider().frame(height: 12) }
            PanelToggle(project: project)
        }
    }
}

private struct BuildStatus: View {
    let project: ProjectModel
    let detail: StatusBar.Detail

    var body: some View {
        let showingIssues = project.panel.shown && project.panel.tab == .issues
        Button {
            if showingIssues { project.panel.shown = false } else { project.panel.show(.issues) }
        } label: { label.fixedSize(horizontal: detail != .short, vertical: true).hitTarget() }
        .help(showingIssues ? "Hide issues" : "Show issues")
    }

    private var label: some View {
        HStack {
            if project.compiling {
                Text("Compiling…")
            } else if let result = project.result {
                if result.stopped {
                    Text("Build Stopped")
                } else if result.ok {
                    badge("Build Succeeded · \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    badge(project.errorCount == 0 ? "Build Failed" : "Build Failed · ^[\(project.errorCount) Error](inflect: true)",
                          "xmark.octagon.fill")
                }
            } else if !project.hasPDF {
                Text("No Build Yet")
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill", spoken: "^[\(project.errorCount) error](inflect: true)")
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill", spoken: "^[\(project.warningCount) warning](inflect: true)")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: project.compiling)
    }

    private func badge(_ title: LocalizedStringKey, _ systemImage: String, _ color: Color? = nil,
                       spoken: LocalizedStringKey? = nil) -> some View {
        Label {
            if let spoken { Text(title).accessibilityLabel(Text(spoken)) } else { Text(title) }
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(color == nil ? .multicolor : nil)
                .foregroundStyle(color ?? .primary)
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
                place(detail, "Line: \(project.cursorLine)  Col: \(project.cursorColumn + 1)",
                      short: "\(project.cursorLine):\(project.cursorColumn + 1)",
                      spoken: "Line \(project.cursorLine), Column \(project.cursorColumn + 1)")
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
                place(detail, "Page \(page) of \(count)", short: "\(page)/\(count)", spoken: "Page \(page) of \(count)")
            }
            .help("Go to a page")
        }
    }

    @ViewBuilder private var freshness: some View {
        if project.showsLastSuccessfulBuild {
            Button { project.panel.show(.issues) } label: {
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
            Label("Build Panel", systemImage: differentiateWithoutColor && !project.panel.shown
                  ? "square" : "inset.filled.bottomthird.square")
                .font(.body)
                .frame(minHeight: BarMetrics.target)
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
    func barRow(leading: CGFloat, trailing: CGFloat) -> some View {
        font(.subheadline).controlSize(.small).lineLimit(1)
            .padding(.leading, leading).padding(.trailing, trailing).frame(height: BarMetrics.height)
    }

    fileprivate func hitTarget() -> some View { frame(minWidth: BarMetrics.target, minHeight: BarMetrics.target).contentShape(.rect) }
}
