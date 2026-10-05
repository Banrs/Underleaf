import SwiftUI

/// Status below source and PDF. Page uses PDFKit numbering, which can differ
/// from LaTeX; save failures and the engine appear elsewhere.
struct StatusBar: View {
    /// Xcode's bar (27), 36 pt: its controls' 20 pt hit targets 8 pt from its top and bottom, in
    /// insets of its own rather than AppKit's 9 pt ones. The folded File Outline's header matches it.
    static let height: CGFloat = 20 + 2 * verticalInset
    static let verticalInset: CGFloat = 8
    /// From the toggle's hit target to the bar's end: its symbol 16.5 pt from the window's edge.
    static let trailingInset: CGFloat = 13
    /// From the bar's start to its first item, as at its end: a leading symbol shows 14 pt in
    /// from the column's edge, as Xcode's first item (Breakpoints) does (27), and text 13.5 pt.
    static let leadingInset: CGFloat = trailingInset
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(showsCounts: true).labelStyle(BarLabelStyle())
            content(showsCounts: false).labelStyle(.iconOnly)
        }
        .font(.subheadline)
        .monospacedDigit()
        .controlSize(.small)
        .lineLimit(1)
        .buttonStyle(.borderless)
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .padding(.vertical, Self.verticalInset)
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    private func content(showsCounts: Bool) -> some View {
        HStack {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus.hitTarget()
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            if project.texpresso.phase != .stopped || project.texpresso.needsAttention {
                separator
                Button { project.showTeXpressoLog() } label: {
                    Label(project.texpresso.title,
                          systemImage: project.texpresso.needsAttention ? "exclamationmark.triangle" : "bolt")
                        .hitTarget()
                }
                .help("Show TeXpresso Log")
            }
            Spacer(minLength: 0)
            let counts = showsCounts && project.editsText && app.showWordCount ? project.counts : nil
            let pages = app.showPDF && project.hasPDF && project.pdf.pageCount > 0
            if project.editsText || pages {
                HStack {
                    if project.editsText {
                        // The caret's place; Go to Line from it.
                        Button { app.perform(.editGotoLine, on: project) } label: {
                            Text("Line: \(project.cursorLine)  Col: \(project.cursorColumn + 1)").hitTarget()
                        }
                        .help("Go to Line")
                    }
                    if let counts {
                        Text("^[\(counts.words) word](inflect: true)")
                            .foregroundStyle(.secondary)
                            .layoutPriority(-1)
                    }
                    if pages {
                        freshness
                        Button { app.perform(.pdfGotoPage, on: project) } label: {
                            Text("Page \(project.pdf.page) of \(project.pdf.pageCount)").hitTarget()
                        }
                        .help("Go to Page")
                    }
                }
                .fixedSize()
            }
            // Xcode's bar end, as measured (27): the hairline 10.5 pt after the text, and the
            // toggle's square symbol 8.5 pt after that.
            HStack(spacing: 5) {
                separator
                Toggle(isOn: $project.showLogs) {
                    Label("Build Panel", systemImage: "inset.filled.bottomthird.square").hitTarget()
                }
                .labelStyle(.iconOnly)
                // Xcode's 13 pt symbol, against the small controls' 10 pt.
                .imageScale(.large)
                .toggleStyle(.button)
                .help(app.title(.viewToggleLogs, on: project))
            }
            .padding(.leading, 2)
        }
    }

    /// The PDF shown isn't the source's: edits since its build, or a failed build after it.
    @ViewBuilder
    private var freshness: some View {
        if project.showsLastSuccessfulBuild {
            Button { project.showBuildPanel() } label: {
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill")
                    .hitTarget()
            }
            .help("The latest PDF build failed; this is the last one that succeeded. Show Issues")
        } else if project.pdfOutdated, !project.livePDF {
            Button { app.perform(.compileRun, on: project) } label: {
                Label("PDF Out of Date", systemImage: "arrow.clockwise")
                    .hitTarget()
            }
            .help(project.texpresso.active
                ? "TeXpresso updates its own window. Compile to refresh this PDF."
                : "The PDF doesn’t reflect the current source. Compile")
            .disabled(!app.isEnabled(.compileRun, on: project))
        }
    }

    private var buildStatus: some View {
        HStack {
            if project.compiling {
                // The mini spinner, about as wide as the other states' symbols.
                Label { Text("Compiling…") } icon: { ProgressView().controlSize(.mini) }
                    .labelStyle(BarLabelStyle())
            } else if let result = project.result {
                if result.stopped {
                    Text("Build Stopped")
                } else if result.ok {
                    badge("Compiled in \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    // The error count folds into the failure, so its symbol shows once.
                    badge(project.errorCount == 0 ? "Build Failed" : "Build Failed · ^[\(project.errorCount) Error](inflect: true)",
                          "xmark.octagon.fill")
                }
            } else {
                Text(project.noBuildTitle)
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill", spoken: "^[\(project.errorCount) error](inflect: true)")
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill", spoken: "^[\(project.warningCount) warning](inflect: true)")
            }
        }
        .fixedSize()
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
        .labelStyle(BarLabelStyle())
    }

    /// Xcode's bar sets its items apart with the system's hairline, as tall as the toggle's
    /// symbol: 9.5–10.5 pt from the text before it, 10 pt to the symbol after it.
    private var separator: some View {
        Divider()
            .frame(height: 12)
    }
}

/// Xcode's bar labels (27): the symbol 4 pt from its title, so it reads as the title's, against
/// about 10 pt between items. A symbol's image carries about 2 pt of margin of its own; the
/// stock `.titleAndIcon` puts 10 pt between symbol and title here, as far as the next item.
private struct BarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

private extension View {
    /// The HIG's 20 × 20 pt least target for a borderless button.
    func hitTarget() -> some View { frame(minWidth: 20, minHeight: 20).contentShape(.rect) }
}
