import SwiftUI

/// Status below source and PDF. Page uses PDFKit numbering, which can differ
/// from LaTeX; save failures, caret line and engine appear elsewhere.
struct StatusBar: View {
    /// Xcode 27's bottom bar, measured; the File Outline's header matches it.
    static let height: CGFloat = 36
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        // Edge to edge, clear of the window's corner: the accessory-bar bezels' own
        // insets (10 pt) set the items apart, and put the toggle's symbol where Xcode's is.
        HStack(spacing: 0) {
            // Reveals the issues, as Xcode's activity view does; the panel's own toggle hides it.
            Button { project.showBuildPanel() } label: { buildStatus }
                .help("Show Issues")
            Spacer(minLength: 0)
            let counts = project.editsText && app.showWordCount ? project.counts : nil
            let pages = app.showPDF && project.hasPDF
            if let counts {
                Text("^[\(counts.words) word](inflect: true)")
                    .foregroundStyle(.secondary)
                    // As a bezel's title is inset (10 pt, small accessory bar).
                    .padding(.horizontal, 10)
                    .layoutPriority(-1)
            }
            if pages {
                if project.showsLastSuccessfulBuild {
                    Button { project.showBuildPanel() } label: {
                        Label("Last Successful Build", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("The latest build failed; this is the last one that succeeded. Show Issues")
                }
                Button("Page \(project.pdf.page) of \(project.pdf.pageCount)") { app.perform(.pdfGotoPage, on: project) }
                    .help("Go to Page")
            }
            if counts != nil || pages {
                // Xcode's bottom bars: a 1 × 12 pt hairline before the panel toggle,
                // 4 pt clear of the bezels either side (measured).
                Divider().frame(height: 12).padding(.horizontal, 4)
            }
            Toggle(isOn: $project.showLogs) {
                Label("Build Panel", systemImage: "inset.filled.bottomthird.rectangle")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .help(app.title(.viewToggleLogs, on: project))
        }
        .font(.subheadline)
        .monospacedDigit()
        .controlSize(.small)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .buttonStyle(.accessoryBar)
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
