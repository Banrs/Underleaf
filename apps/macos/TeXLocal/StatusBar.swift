import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 36
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 16.5
    static let spacing: CGFloat = 9
    static let groupSpacing: CGFloat = 16
    static let consoleLeading: CGFloat = 12
    static let consoleTrailing: CGFloat = 17
    static let target: CGFloat = 20
    static let dividerHeight: CGFloat = 12
}

/// Page uses PDFKit numbering, which can differ from LaTeX.
struct StatusBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let project: ProjectModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full).labelStyle(.titleAndIcon)
            content(.symbols).labelStyle(.iconOnly)
            content(.short).labelStyle(.iconOnly)
        }
        .barRow(leading: BarMetrics.leading, trailing: BarMetrics.trailing)
        // Its ground and line are a `BarGround` under it (`WorkspaceController.buildStatusBar`), level with the File Outline header's.
        // Clicks between its controls stay with the bar, not the text or pages scrolled beneath it.
        .contentShape(.rect)
        .monospacedDigit()
        .buttonStyle(.borderless)
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    private enum Detail { case full, symbols, short }

    private func content(_ detail: Detail) -> some View {
        HStack(spacing: BarMetrics.spacing) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.panel.shown && project.panel.tab == .issues
            Button {
                if showingIssues { project.panel.shown = false } else { project.panel.show(.issues) }
            } label: { buildStatus.fixedSize(horizontal: detail != .short, vertical: true).hitTarget() }
            .help(showingIssues ? "Hide issues" : "Show issues")
            if project.texpresso.phase != .stopped || project.texpresso.needsAttention {
                Button { project.panel.show(.texpresso) } label: {
                    Label(project.texpresso.title, systemImage: project.texpresso.needsAttention ? "exclamationmark.triangle" : "bolt")
                        .hitTarget()
                }
                .help("Show the Live Preview log")
            }
            if let reason = project.saveFailure {
                Button { Task { await project.save() } } label: {
                    Label("Not Saved", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .hitTarget()
                }
                .help("\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason); save again")
            }
            if let notice = project.notices.current { Text(notice).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            let words = detail == .full && project.editsText && app.showWordCount ? project.words : nil
            let pages = app.showPDF && project.hasPDF && project.pdf.pageCount > 0
            HStack(spacing: BarMetrics.groupSpacing) {
                if project.editsText {
                    Button { app.perform(.editGotoLine, on: project) } label: {
                        place(detail, "Line: \(project.cursorLine)  Col: \(project.cursorColumn + 1)",
                              short: "\(project.cursorLine):\(project.cursorColumn + 1)",
                              spoken: "Line \(project.cursorLine), Column \(project.cursorColumn + 1)")
                    }
                    .help("Go to a line")
                }
                if let words {
                    Text("^[\(words) word](inflect: true)")
                        .foregroundStyle(.secondary)
                        .layoutPriority(-1)
                }
                if pages {
                    freshness
                    Button { app.perform(.pdfGotoPage, on: project) } label: {
                        place(detail, "Page \(project.pdf.page) of \(project.pdf.pageCount)",
                              short: "\(project.pdf.page)/\(project.pdf.pageCount)",
                              spoken: "Page \(project.pdf.page) of \(project.pdf.pageCount)")
                    }
                    .help("Go to a page")
                }
            }
            .fixedSize()
            if project.editsText || pages { Divider().frame(height: BarMetrics.dividerHeight) }
            Toggle(isOn: Bindable(project.panel).shown) {
                // Its state is the accent colour alone: with Differentiate Without Colour the off state is the plain square, without the panel's filled third.
                Label("Build Panel", systemImage: differentiateWithoutColor && !project.panel.shown
                      ? "square" : "inset.filled.bottomthird.square")
                    .font(.body)
                    .frame(minHeight: BarMetrics.target)
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .help(app.title(.viewToggleLogs, on: project))
        }
    }

    private func place(_ detail: Detail, _ full: LocalizedStringKey, short: String, spoken: LocalizedStringKey) -> some View {
        Group { if detail == .short { Text(verbatim: short).accessibilityLabel(spoken) } else { Text(full) } }
        .hitTarget()
    }

    @ViewBuilder private var freshness: some View {
        if project.showsLastSuccessfulBuild {
            Button { project.panel.show(.issues) } label: {
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill").hitTarget()
            }
            .help("The latest build failed, so this is the last PDF that built")
        } else if project.outdated, !project.livePDF {
            Button { app.perform(.compileRun, on: project) } label: {
                Label("PDF Out of Date", systemImage: "arrow.clockwise").hitTarget()
            }
            .help(project.texpresso.active
                ? "Live Preview updates its own window; compile to refresh this PDF"
                : "The PDF is older than the source; compile to refresh it")
            .disabled(!app.isEnabled(.compileRun, on: project))
        }
    }

    private var buildStatus: some View {
        HStack {
            if project.compiling {
                // The toolbar's Stop has the build's one spinner.
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
            } else {
                Text("No Build Yet")
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill", spoken: "^[\(project.errorCount) error](inflect: true)")
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill", spoken: "^[\(project.warningCount) warning](inflect: true)")
            }
        }
        // A build starting or ending crossfades its status, also under Reduce Motion, where the HIG has a crossfade stand for motion.
        .animation(.easeInOut(duration: 0.2), value: project.compiling)
    }

    /// `spoken` is what the short `title` stands for, so VoiceOver and Voice Control name the badge "3 errors", not "3".
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

extension View {
    func barRow(leading: CGFloat, trailing: CGFloat) -> some View {
        font(.subheadline).controlSize(.small).lineLimit(1)
            .padding(.leading, leading).padding(.trailing, trailing).frame(height: BarMetrics.height)
    }

    fileprivate func hitTarget() -> some View {
        frame(minWidth: BarMetrics.target, minHeight: BarMetrics.target).contentShape(.rect)
    }
}
