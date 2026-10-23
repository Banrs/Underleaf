import AppKit
import SwiftUI

struct PDFPane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @AppStorage(DefaultsKey.pdfPaper) private var paper = PDFPaper.white
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if project.hasPDF {
            // Not in a SwiftUI scroll view, which would take PDFKit's rubber-banding and insets (27.2).
            PDFRepresentable(project: project, darkPaper: paper.isDark(in: colorScheme))
                .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.textSurface)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.installingTeX {
            ContentUnavailableView {
                Label("Installing TinyTeX…", systemImage: "richtext.page")
            } description: {
                Text("This can take a few minutes.")
            } actions: {
                ProgressView()
            }
        } else if app.tex?.available != true {
            ContentUnavailableView {
                Label("TeX Isn’t Installed", systemImage: "richtext.page")
            } description: {
                Text("Install TinyTeX to compile, or get MacTeX, the full TeX distribution.")
            } actions: {
                Button("Install TinyTeX") {
                    Task {
                        do { try await app.installTeX() } catch { app.report(error, "Couldn’t Install TinyTeX") }
                    }
                }
                .buttonStyle(.borderedProminent)
                LinkButton(title: "Get MacTeX", url: Links.mactex)
            }
        } else if project.compiling {
            // The toolbar's Stop can be in its overflow menu (HIG, Progress indicators).
            ContentUnavailableView {
                Label("Compiling…", systemImage: "richtext.page")
            } actions: {
                ProgressView()
            }
        } else if project.result?.failed == true {
            ContentUnavailableView {
                Label("Build Failed", systemImage: "xmark.octagon")
            } description: {
                Text("The build made no PDF. The build panel shows what went wrong.")
            } actions: {
                if !project.panel.shown {
                    Button("Show Build Panel") { project.panel.show(.issues) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Yet", systemImage: "richtext.page")
            } description: {
                Text("Compile to preview your document.")
            } actions: {
                Button("Compile") { app.perform(.compileRun, on: project) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!app.isEnabled(.compileRun, on: project))
            }
        }
    }
}

struct PDFRepresentable: NSViewRepresentable {
    let project: ProjectModel
    let darkPaper: Bool

    func makeNSView(context: Context) -> SyncPDFView {
        let view = project.pdf.view
        view.onInverse = { [weak project] page, point, click in
            Task { await project?.inverseSync(page: page, x: point.x, y: point.y, click: click) }
        }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) { view.darkPaper = darkPaper }
}

struct PDFFindBar: View {
    @Bindable var find: PDFFind

    var body: some View {
        // For the query the matches are for, which the field can be ahead of.
        let label = PDFFind.count(find.matchIndex + 1, of: find.matches.count, limited: find.limited, for: find.query)
        HStack {
            SearchField(text: $find.text, prompt: "Find in PDF", handle: find.field,
                        step: find.next, close: find.close)
                .frame(minWidth: 100, maxWidth: .infinity)
            ControlGroup {
                Button("Previous Match", systemImage: "chevron.backward") { find.next(-1) }
                    .help("Go to the previous match")
                Button("Next Match", systemImage: "chevron.forward") { find.next(1) }
                    .help("Go to the next match")
            }
            .disabled(find.matches.isEmpty)
            .fixedSize()
            Text(label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .layoutPriority(-1)
            Button("Done") { find.close() }
        }
        .lineLimit(1)
        // VoiceOver's focus stays in the field: it hears the count once it settles.
        .task(id: label) {
            guard !label.isEmpty, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            var spoken = AttributedString(label)
            spoken.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(spoken).post()
        }
        .task(id: find.text) {
            try? await Task.sleep(for: PDFFind.debounce)
            if !Task.isCancelled { find.typed() }
        }
    }
}

/// The zoom menu's choices, ticked as a menu's picker ticks its selection.
struct ScaleMenuItems: View {
    let pdf: PDFController

    var body: some View {
        Picker("Zoom", selection: Binding(get: { shown }, set: pdf.apply)) {
            Text("Fit Width").tag(PDFController.Zoom.fitWidth)
            Text("Fit Page").tag(PDFController.Zoom.fitPage)
            Divider()
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { scale in
                Text(scale.formatted(.percent)).tag(PDFController.Zoom.scale(scale))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// A scale to the nearest percent, so a pinch that ends at 99.6% ticks 100%.
    private var shown: PDFController.Zoom {
        guard case .scale(let scale) = pdf.zoom else { return pdf.zoom }
        return .scale((scale * 100).rounded() / 100)
    }
}
