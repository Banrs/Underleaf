import SwiftUI

/// The status bar under the source and the PDF: the build's summary, which shows
/// its issues; the word count (View › Show Word Count); whether the PDF is out of
/// date; its page, which opens Go to Page (the PDF's own numbers, not LaTeX's,
/// which front matter and roman numbering change); and the build panel's toggle at
/// the far end. Not here: the save state (edits save themselves 0.7 s after typing
/// stops, and a failed save is an alert), the caret's line (the gutter marks it)
/// and the engine (the inspector).
struct StatusBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    let pdf: PDFController

    var body: some View {
        SecondaryBar(spacing: BarMetrics.itemSpacing) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            Spacer(minLength: 0)
            if project.editsText, app.showWordCount, let counts = project.counts {
                Text("^[\(counts.words) word](inflect: true)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .layoutPriority(-1)
            }
            if project.showPDF, project.pdfVersion > 0, pdf.pageCount > 0 {
                if let freshness = project.pdfFreshness { freshnessButton(freshness) }
                Button("Page \(pdf.page) of \(pdf.pageCount)") { app.perform(.pdfGotoPage, on: project) }
                    .monospacedDigit()
                    .help("Go to Page")
            }
            BuildPanelToggle(project: project)
        }
        .buttonStyle(.borderless)
        // What the bar shows is chosen where it shows (and View › Show Word Count).
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    /// Why the pages may not match the source, by the page they concern: edits since
    /// the build (Compile), or the last build that worked after one that failed.
    private func freshnessButton(_ freshness: PDFFreshness) -> some View {
        Button {
            if freshness == .edited { app.perform(.compileRun, on: project) } else { project.showBuildPanel() }
        } label: {
            Label(freshness.title, systemImage: freshness.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .help(freshness == .edited ? "The preview doesn’t reflect the current source. Compile"
                                   : "The latest build failed; this is the last one that succeeded. Show Issues")
    }

    /// Only the symbols carry colour; the words stay secondary.
    private var buildStatus: some View {
        HStack(spacing: BarMetrics.groupSpacing) {
            if project.compiling {
                ProgressView()
                Text("Compiling…")
            } else if let result = project.result {
                if result.stopped {
                    Text("Build Stopped")
                } else if result.ok {
                    badge("Compiled in \(result.durationText)", "checkmark.circle.fill", .green)
                } else {
                    // The error count folds into the failure, so its symbol shows once.
                    badge(failedTitle, "xmark.octagon.fill", .red)
                }
            } else {
                Text(project.noBuildTitle)
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill", .red)
                    .accessibilityLabel(Text("^[\(project.errorCount) error](inflect: true)"))
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill", .orange)
                    .accessibilityLabel(Text("^[\(project.warningCount) warning](inflect: true)"))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private var failedTitle: String {
        switch project.errorCount {
        case 0: "Build Failed"
        case 1: "Build Failed · 1 Error"
        case let count: "Build Failed · \(count) Errors"
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
}

/// Shows and hides the build panel, at the status bar's far end, as a panel's
/// toggle sits at its window's edge.
private struct BuildPanelToggle: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        Toggle(isOn: $project.showLogs) {
            Label("Build Panel", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .help(app.title(.viewToggleLogs, on: project))
    }
}
