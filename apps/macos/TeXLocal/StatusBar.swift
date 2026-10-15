import SwiftUI

/// The bars' numbers, Xcode's, measured (2026-10-06). Most are the UI kit's too: 36 is an
/// extra-large control and also 8 + a small control (20) + 8, 14 is the sidebar's content inset
/// and 9 the toolbar button group's gap. 16.5, 12, 17 and 16 have no kit symbol.
enum BarMetrics {
    /// A toolbar control's height, which the status bar, the build panel's bar and the folded
    /// File Outline's header share.
    static let height: CGFloat = 36
    /// The line over a bar: a point, as the window's splits' dividers and as Xcode's (27.1), in a
    /// row of its own above the bar's height.
    static let line: CGFloat = 1
    /// The status bar's edges: 14 pt in to its first item, and the toggle's symbol 17.5 pt from
    /// the right edge, 3.5 pt of which its target beyond the glyph makes up.
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 16.5
    /// Between a bar's items, and between its groups of them.
    static let spacing: CGFloat = 9
    static let groupSpacing: CGFloat = 16
    /// The build panel's bar, as Xcode's console bar: its pop-up's text 16 pt in, its last
    /// control's glyph 17 pt from the edge.
    static let consoleLeading: CGFloat = 12
    static let consoleTrailing: CGFloat = 17
    /// The HIG's 20 × 20 pt least target for a borderless button, a small control's height.
    static let target: CGFloat = 20
    /// The line before the toggle: as tall as the toggle's symbol.
    static let dividerHeight: CGFloat = 12
}

/// Status below source and PDF, which scroll on beneath it, the same whether the build panel
/// shows or not. Page uses PDFKit numbering, which can differ from LaTeX; the engine appears
/// elsewhere.
struct StatusBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let project: ProjectModel

    var body: some View {
        // Under a narrower window the bar says less, then says it shorter.
        ViewThatFits(in: .horizontal) {
            content(.full).labelStyle(.titleAndIcon)
            content(.symbols).labelStyle(.iconOnly)
            content(.short).labelStyle(.iconOnly)
        }
        .barRow(leading: BarMetrics.leading, trailing: BarMetrics.trailing)
        // Its line's row, the row of the line over the File Outline's header beside it (`HeaderEdge`).
        .padding(.top, BarMetrics.line)
        // No ground of its own: AppKit's scroll edge lies under the bar (`buildArea`), and draws
        // no line, so the bar has its own.
        .overlay(alignment: .top) { Divider() }
        .monospacedDigit()
        .buttonStyle(.borderless)
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    private nonisolated enum Detail { case full, symbols, short }

    private func content(_ detail: Detail) -> some View {
        HStack(spacing: BarMetrics.spacing) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.panel.shown && project.panel.tab == .issues
            Button {
                if showingIssues { project.panel.shown = false } else { project.panel.show(.issues) }
            } label: {
                // The last to give way: its text shortens only where nothing else can.
                buildStatus.fixedSize(horizontal: detail != .short, vertical: true).hitTarget()
            }
            .help(showingIssues ? "Hide issues" : "Show issues")
            if project.texpresso.phase != .stopped || project.texpresso.needsAttention {
                Button { project.panel.show(.texpresso) } label: {
                    Label(project.texpresso.title,
                          systemImage: project.texpresso.needsAttention ? "exclamationmark.triangle" : "bolt")
                        .hitTarget()
                }
                .help("Show the Live Preview log")
            }
            if let reason = project.saveFailure {
                // An autosave's failure, here until a save succeeds; saving again says why in an alert.
                Button { Task { await project.saveEdits() } } label: {
                    Label("Not Saved", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .hitTarget()
                }
                // A fragment, as the bar's other help tags: the reason without its full stop.
                .help("\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason); save again")
            }
            if let notice = project.notices.current {
                Text(notice).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            let words = detail == .full && project.editsText && app.showWordCount ? project.words : nil
            let pages = app.showPDF && project.hasPDF && project.pdf.pageCount > 0
            HStack(spacing: BarMetrics.groupSpacing) {
                if project.editsText {
                    // The caret's place; Go to Line from it.
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
            // Xcode's line before the toggle, 9 pt either side.
            if project.editsText || pages {
                Divider().frame(height: BarMetrics.dividerHeight)
            }
            Toggle(isOn: Bindable(project.panel).shown) {
                // Only as tall as the HIG's least target: its symbol sits at Xcode's gaps, at the body
                // size, the nearest to Xcode's 12.5 pt symbol beside 11 pt text (measured 2026-10-06).
                // Its state is the accent colour alone: with Differentiate Without Colour the off
                // state is the plain square, without the panel's filled third.
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

    /// The caret's or the page's place, in words until the bar must shorten it to figures, which
    /// then carry the words for VoiceOver.
    private func place(_ detail: Detail, _ full: LocalizedStringKey, short: String,
                       spoken: LocalizedStringKey) -> some View {
        Group {
            if detail == .short { Text(verbatim: short).accessibilityLabel(spoken) } else { Text(full) }
        }
        .hitTarget()
    }

    /// The PDF shown isn't the source's: edits since its build, or a failed build after it.
    @ViewBuilder
    private var freshness: some View {
        if project.showsLastSuccessfulBuild {
            Button { project.panel.show(.issues) } label: {
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill")
                    .hitTarget()
            }
            .help("The latest build failed, so this is the last PDF that built")
        } else if project.pdfOutdated, !project.livePDF {
            Button { app.perform(.compileRun, on: project) } label: {
                Label("PDF Out of Date", systemImage: "arrow.clockwise")
                    .hitTarget()
            }
            .help("The PDF is older than the source; compile to refresh it")
            .disabled(!app.isEnabled(.compileRun, on: project))
        }
    }

    private var buildStatus: some View {
        HStack {
            if project.compiling {
                // The build's one spinner: the toolbar's Stop keeps Compile's place.
                ProgressView().accessibilityHidden(true)
                Text("Compiling…")
            } else if let result = project.result {
                if result.stopped {
                    Text("Build Stopped")
                } else if result.ok {
                    badge("Build Succeeded · \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    // The error count folds into the failure, so its symbol shows once.
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
        // A build starting or ending crossfades its status, under Reduce Motion too, where the HIG
        // has a crossfade stand for motion; nothing here moves with typing.
        .animation(.easeInOut(duration: 0.2), value: project.compiling)
    }

    /// `spoken` is what the short `title` stands for, as the title itself, so VoiceOver and
    /// Voice Control name the badge "3 errors", not "3".
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
    /// A bar's row, as Xcode's: small controls and subheadline text on one line, in from the
    /// bar's edges, 36 pt high under its line (8 + a small control + 8).
    func barRow(leading: CGFloat, trailing: CGFloat) -> some View {
        font(.subheadline).controlSize(.small).lineLimit(1)
            .padding(.leading, leading).padding(.trailing, trailing).frame(height: BarMetrics.height)
    }

    fileprivate func hitTarget() -> some View {
        frame(minWidth: BarMetrics.target, minHeight: BarMetrics.target).contentShape(.rect)
    }
}
