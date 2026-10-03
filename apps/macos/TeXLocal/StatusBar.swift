import SwiftUI

/// Status below source and PDF. Page uses PDFKit numbering, which can differ
/// from LaTeX; save failures, caret line and engine appear elsewhere.
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
                buildStatus.hitTarget()
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
                                Text("Page \(project.pdf.page) of \(project.pdf.pageCount)").hitTarget()
                            }
                            .help("Go to Page")
                        }
                    }
                    // Xcode's bottom bars: a 1 × 12 pt hairline before the panel toggle.
                    Divider().frame(height: 12)
                }
                Toggle(isOn: $project.showLogs) {
                    Label("Build Panel", systemImage: "inset.filled.bottomthird.rectangle").hitTarget()
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                // Laid out by its symbol, as a text button is by its words, so the bar's
                // inset and spacing reach the symbol: its 20 pt hit area reaches past.
                .padding(.horizontal, -3)
                .help(app.title(.viewToggleLogs, on: project))
            }
        }
        .font(Typography.secondary)
        .monospacedDigit()
        .controlSize(.small)
        .lineLimit(1)
        .padding(.horizontal, BarMetrics.inset)
        .frame(height: BarMetrics.secondaryBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.borderless)
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    /// Action for unbuilt edits or a failed build with an older PDF.
    private func freshnessButton(_ freshness: PDFFreshness) -> some View {
        Button {
            if freshness == .edited { app.perform(.compileRun, on: project) } else { project.showBuildPanel() }
        } label: {
            Label(freshness.title, systemImage: freshness.systemImage)
                .labelStyle(.titleAndIcon)
                .hitTarget()
        }
        .help(freshness == .edited ? "The preview doesn’t reflect the current source. Compile"
                                   : "The latest build failed; this is the last one that succeeded. Show Issues")
    }

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
        .fixedSize()
    }

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

private extension View {
    /// The HIG's 20 × 20 pt minimum for borderless button targets.
    func hitTarget() -> some View { frame(minWidth: 20, minHeight: 20).contentShape(.rect) }
}
