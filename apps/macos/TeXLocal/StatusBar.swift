import SwiftUI

/// The status bar under the source and the PDF. Its page is the PDF's own number, not
/// LaTeX's, which front matter and roman numbering change. No save state (edits save
/// 0.7 s after typing; a failed save is an alert), caret line (the gutter) or engine (the inspector).
struct StatusBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            Spacer(minLength: 0)
            HStack {
                let counts = project.editsText && app.showWordCount ? project.counts : nil
                let pages = project.showPDF && project.pdfVersion > 0 && project.pdf.pageCount > 0
                if counts != nil || pages {
                    HStack(spacing: BarMetrics.itemSpacing) {
                        if let counts {
                            Text("^[\(counts.words) word](inflect: true)")
                                .foregroundStyle(.secondary)
                                .layoutPriority(-1)
                        }
                        if pages {
                            if let freshness = project.pdfFreshness { freshnessButton(freshness) }
                            Button { app.perform(.pdfGotoPage, on: project) } label: {
                                Text("Page \(project.pdf.page) of \(project.pdf.pageCount)")
                            }
                            .help("Go to Page")
                        }
                    }
                    Divider().frame(height: 12)
                }
                // At the far end, as a panel's toggle sits at its window's edge.
                Toggle(isOn: $project.showLogs) {
                    Label("Build Panel", systemImage: "inset.filled.bottomthird.rectangle")
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                .help(app.title(.viewToggleLogs, on: project))
            }
        }
        .font(Typography.secondary)
        .monospacedDigit()
        .controlSize(.small)
        .lineLimit(1)
        .frame(height: BarMetrics.secondaryBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().allowsHitTesting(false) }
        .buttonStyle(.accessoryBar)
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
        HStack {
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
                    badge(project.errorCount == 0 ? "Build Failed" : "Build Failed · ^[\(project.errorCount) Error](inflect: true)",
                          "xmark.octagon.fill")
                }
            } else {
                Text(project.noBuildTitle)
            }
            if project.errorCount > 0, project.result?.failed != true {
                badge("\(project.errorCount)", "xmark.octagon.fill")
                    .accessibilityLabel(Text("^[\(project.errorCount) error](inflect: true)"))
            }
            if project.warningCount > 0 {
                badge("\(project.warningCount)", "exclamationmark.triangle.fill")
                    .accessibilityLabel(Text("^[\(project.warningCount) warning](inflect: true)"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Errors and warnings in the symbols' own colours; success in green, which
    /// the multicolour checkmark isn't.
    private func badge(_ title: LocalizedStringKey, _ systemImage: String, _ color: Color? = nil) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(color == nil ? .multicolor : nil)
                .foregroundStyle(color ?? .primary)
        }
        .labelStyle(.titleAndIcon)
    }
}
