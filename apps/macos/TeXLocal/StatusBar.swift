import SwiftUI

/// Status below source and PDF, the same whether the build panel shows or not. Page uses
/// PDFKit numbering, which can differ from LaTeX; save failures and the engine appear elsewhere.
struct StatusBar: View {
    /// The bar's height, which the folded File Outline's header shares (`OutlineHeader`).
    static let height: CGFloat = 36
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            // Over the bar, as the folded File Outline's line is over its header.
            Divider()
            ViewThatFits(in: .horizontal) {
                content(showsCounts: true).labelStyle(.titleAndIcon)
                content(showsCounts: false).labelStyle(.iconOnly)
            }
            // Xcode's bar, measured (2026-10-06): 36 pt under its hairline, 14 pt in to the first
            // item, the toggle's symbol 17.5 pt from the right edge.
            .padding(.leading, 14)
            .padding(.trailing, 16.5)
            .frame(height: Self.height)
        }
        .font(.subheadline)
        .monospacedDigit()
        .controlSize(.small)
        .lineLimit(1)
        .buttonStyle(.borderless)
        // Opaque in the editors' colour, as Xcode's: the system's edge is a material the text shows through.
        .background(Color(nsColor: .untintedTextBackground))
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    private func content(showsCounts: Bool) -> some View {
        // Xcode's hairline before the toggle, 9 pt either side.
        HStack(spacing: 9) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus.hitTarget()
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            if project.texpresso.phase != .stopped || project.texpresso.needsAttention {
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
            HStack(spacing: 16) {
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
            if project.editsText || pages { hairline }
            Toggle(isOn: $project.showLogs) {
                // Only as tall as the HIG's least target: its symbol sits at Xcode's gaps.
                Label("Build Panel", systemImage: "inset.filled.bottomthird.square").frame(minHeight: 20)
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .help(app.title(.viewToggleLogs, on: project))
        }
    }

    /// Xcode's: as tall as the toggle's symbol.
    private var hairline: some View { Divider().frame(height: 12) }

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
                    .labelStyle(.titleAndIcon)
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
        // A build starting or ending crossfades its status; nothing here moves with typing.
        .animation(reduceMotion ? nil : .snappy, value: project.compiling)
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

private extension View {
    /// The HIG's 20 × 20 pt least target for a borderless button.
    func hitTarget() -> some View { frame(minWidth: 20, minHeight: 20).contentShape(.rect) }
}
