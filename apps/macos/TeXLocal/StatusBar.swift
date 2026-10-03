import SwiftUI

/// Status below source and PDF. Page uses PDFKit numbering, which can differ
/// from LaTeX; save failures and the engine appear elsewhere.
struct StatusBar: View {
    /// Xcode 27's bottom bar, measured; the folded File Outline's header matches it.
    static let height: CGFloat = 36
    /// Xcode's bottom bar, measured: its first item's ink 14 pt in, its last symbol's
    /// 17 pt from the window's edge (clear of the corner), 9 pt either side of a hairline.
    /// Less a point at the ends for the glyphs' own side bearing and the toggle's frame.
    private static let leading: CGFloat = 13
    private static let trailing: CGFloat = 16
    private static let gap: CGFloat = 9
    /// Between items without a hairline, as far apart as across one.
    private static let itemSpacing = gap + 1 + gap
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        HStack(spacing: Self.gap) {
            // A button, not a toggle: the panel's own toggle is the one place its open state shows.
            let showingIssues = project.showLogs && project.panelTab == .issues
            Button {
                if showingIssues { project.showLogs = false } else { project.showBuildPanel() }
            } label: {
                buildStatus.hitTarget()
            }
            .help(showingIssues ? "Hide Issues" : "Show Issues")
            Spacer(minLength: 0)
            let counts = project.editsText && app.showWordCount ? project.counts : nil
            let pages = app.showPDF && project.hasPDF && project.pdf.pageCount > 0
            if project.editsText || pages {
                HStack(spacing: Self.itemSpacing) {
                    if project.editsText {
                        // Xcode's caret position; Go to Line from it.
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
                // Xcode's bottom bars: a 1 × 12 pt hairline before the panel toggle.
                Divider().frame(height: 12)
            }
            Toggle(isOn: $project.showLogs) {
                Label("Build Panel", systemImage: "inset.filled.bottomthird.rectangle").hitTarget()
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            // Laid out by its symbol, as a text button is by its words, so the bar's
            // ends and gaps reach the symbol: its 20 pt hit area reaches past.
            .padding(.horizontal, -3)
            .help(app.title(.viewToggleLogs, on: project))
        }
        .font(.subheadline)
        .monospacedDigit()
        .controlSize(.small)
        .lineLimit(1)
        .padding(.leading, Self.leading)
        .padding(.trailing, Self.trailing)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .buttonStyle(.borderless)
        .contextMenu {
            Button(app.title(.viewToggleWordCount, on: project)) { app.perform(.viewToggleWordCount, on: project) }
        }
    }

    /// The PDF shown isn't the source's: edits since its build, or a failed build after it.
    @ViewBuilder
    private var freshness: some View {
        if project.showsLastSuccessfulBuild {
            Button { project.showBuildPanel() } label: {
                Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .hitTarget()
            }
            .help("The latest build failed; this is the last one that succeeded. Show Issues")
        } else if project.pdfOutdated {
            Button { app.perform(.compileRun, on: project) } label: {
                Label("Preview Out of Date", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .hitTarget()
            }
            .help("The preview doesn’t reflect the current source. Compile")
            .disabled(!app.isEnabled(.compileRun, on: project))
        }
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
    /// The HIG's 20 × 20 pt least target for a borderless button.
    func hitTarget() -> some View { frame(minWidth: 20, minHeight: 20).contentShape(.rect) }
}
