import AppKit
import SwiftUI

struct PDFEmptyState: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        content
            .buttonStyle(.bordered)
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
                Text("The build made no PDF. The Issues navigator shows what went wrong.")
            } actions: {
                Button("Show Issues") { project.showNavigator(.issues) }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Yet", systemImage: "richtext.page")
            } description: {
                Text("Compile to preview your document.")
            } actions: {
                Button("Compile") { window.perform(.compileRun, on: project) }
                    .disabled(!app.isEnabled(.compileRun, on: project))
            }
        }
    }
}

struct PDFFindBar: View {
    @Bindable var find: PDFFind

    var body: some View {
        let label = PDFFind.count(find.matchIndex + 1, of: find.matches.count, limited: find.limited, for: find.query)
        // NSTextFinder's bar, read from an NSTextView's own: small controls 8 pt in and apart, 6 pt from its top and foot; the
        // match count inside the field; chevrons drawn 7 pt square in 16 pt segments; Done an accessory bar button.
        HStack(spacing: 8) {
            SearchField(text: $find.text, prompt: "Find", handle: find.field, step: find.next, close: find.close,
                        status: find.query.isEmpty ? "" : find.matches.count.formatted() + (find.limited ? "+" : ""))
            ControlGroup {
                Button { find.next(-1) } label: { Label { Text("Previous Match") } icon: { Self.back } }
                    .help("Go to the previous match")
                Button { find.next(1) } label: { Label { Text("Next Match") } icon: { Self.forward } }
                    .help("Go to the next match")
            }
            .frame(width: 32)
            .disabled(find.matches.isEmpty)
            Button("Done") { find.close() }
                .buttonStyle(.accessoryBarAction)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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

    private static let back = chevron("chevron.backward"), forward = chevron("chevron.forward")

    private static func chevron(_ name: String) -> Image {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.copy() as? NSImage ?? NSImage()
        image.size = NSSize(width: 7, height: 7)
        return Image(nsImage: image)
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
