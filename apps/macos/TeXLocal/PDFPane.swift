import AppKit
import SwiftUI

struct PDFEmptyState: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.textSurface)
    }

    @ViewBuilder
    private var content: some View {
        if app.installingTeX {
            ContentUnavailableView {
                Label("Installing TinyTeX…", systemImage: "richtext.page")
            } description: {
                Text("This can take a few minutes.")
            } actions: {
                ProgressView()
            }
        } else if app.tex?.available == false {
            ContentUnavailableView {
                Label("TeX Isn’t Installed", systemImage: "richtext.page")
            } description: {
                Text("Install TinyTeX to compile, or get MacTeX, the full TeX distribution.")
            } actions: {
                Button("Install TinyTeX") {
                    Task {
                        do { try await app.installTeX() } catch { window.report("Couldn’t Install TinyTeX", error) }
                    }
                }
                .buttonStyle(.borderedProminent)
                Link("Get MacTeX", destination: Links.mactex)
            }
        } else if project.compiling {
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
                Button("Compile") { window.perform(.compileRun, on: project) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!app.isEnabled(.compileRun, on: project))
            }
        }
    }
}

struct PDFFindBar: View {
    @Bindable var find: PDFFind

    var body: some View {
        let label = PDFFind.count(find.matchIndex + 1, of: find.matches.count, limited: find.limited, for: find.query)
        HStack {
            SearchField(text: $find.text, prompt: "Find in PDF", handle: find.field,
                        step: find.next, close: find.close)
                .frame(minWidth: 100, maxWidth: 240)
            ControlGroup {
                Button("Previous Match", systemImage: "chevron.backward") { find.next(-1) }
                    .help("Go to the previous match")
                Button("Next Match", systemImage: "chevron.forward") { find.next(1) }
                    .help("Go to the next match")
            }
            .disabled(find.matches.isEmpty)
            .fixedSize()
            ViewThatFits(in: .horizontal) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Color.clear.frame(width: 0)
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
                .layoutPriority(-2)
            Button("Done") { find.close() }
        }
        .lineLimit(1)
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

struct ScaleMenuItems: View {
    let pdf: PDFController

    var body: some View {
        Picker("Zoom", selection: Binding(get: { shown }, set: pdf.apply)) {
            Text("Fit Width").tag(Zoom.fitWidth)
            Text("Fit Page").tag(Zoom.fitPage)
            Divider()
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { scale in
                Text(scale.formatted(.percent)).tag(Zoom.scale(scale))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var shown: Zoom {
        guard case .scale(let scale) = pdf.zoom else { return pdf.zoom }
        return .scale((scale * 100).rounded() / 100)
    }
}
