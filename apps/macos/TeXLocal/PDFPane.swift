import PDFKit
import SwiftUI

/// The compiled PDF in PDFKit: native rendering, selection, zoom and find. Its
/// tools are the toolbar's, its find bar is the column's top accessory, and its
/// page is in the status bar.
struct PDFPane: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    /// The document read for a `pdfVersion`.
    @State private var loaded: (version: Int, document: PDFDocument)?

    var body: some View {
        pages
            // Keyed on hasPDF too: the URL can arrive after the version.
            .task(id: project.hasPDF ? project.pdfVersion : 0) {
                let version = project.pdfVersion
                guard project.hasPDF, let url = project.pdfURL else { return }
                // A newer version's read may have finished first.
                if let document = await Self.loadDocument(url), !Task.isCancelled { loaded = (version, document) }
            }
    }

    /// Read whole: the next build rewrites the file in place.
    @concurrent nonisolated static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else { return nil }
        // Keep hyperlinks active without hyperref's visible annotation boxes.
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
            }
        }
        return document
    }

    @ViewBuilder
    private var pages: some View {
        if project.pdfVersion > 0 {
            PDFRepresentable(project: project, document: loaded?.document, current: loaded?.version == project.pdfVersion)
                .ignoresSafeArea(.container, edges: [.top, .trailing])
        } else {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// No PDF: TeX to install, a build that failed before making one, or
    /// nothing compiled yet.
    @ViewBuilder
    private var emptyState: some View {
        if !project.texAvailable {
            ContentUnavailableView {
                Label("TeX Isn’t Installed", systemImage: "richtext.page")
            } description: {
                Text("Install MacTeX to compile. TeXLocal notices it once it’s there.")
            } actions: {
                GetMacTeXButton().buttonStyle(.borderedProminent)
            }
        } else if project.result?.failed == true {
            ContentUnavailableView {
                Label("Build Failed", systemImage: "xmark.octagon")
            } description: {
                Text("The build made no PDF. The build panel shows what went wrong.")
            } actions: {
                if !project.showLogs {
                    Button("Show Build Panel") { project.showBuildPanel() }
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

/// Find in PDF: the source's find bar without its replace row.
struct PDFFindBar: View {
    @Bindable var controller: PDFController

    var body: some View {
        FindBar(query: $controller.findText, prompt: "Find in PDF", field: controller.findField,
                matches: FindMatches(index: controller.matchIndex + 1, total: controller.matches.count,
                                     limited: controller.limited),
                searched: controller.query, step: controller.step, close: controller.closeFind) {}
            .task(id: controller.findText) {
                try? await Task.sleep(for: PDFFind.debounce)
                if !Task.isCancelled, PDFFind.normalize(controller.findText) != controller.query {
                    controller.find(controller.findText)
                }
            }
    }
}

/// The fits and preset scales, the one in use checked (none while it's between
/// presets), for the toolbar's scale menu (`NSHostingMenu`); View has the fits and
/// the zooms with their shortcuts.
struct ScaleMenuItems: View {
    let pdf: PDFController
    private static let presets = [50, 75, 100, 125, 150, 200]

    var body: some View {
        Toggle("Fit Width", isOn: choice(pdf.fit == .width) { pdf.fitWidth() })
        Toggle("Fit Height", isOn: choice(pdf.fit == .height) { pdf.fitHeight() })
        Divider()
        ForEach(Self.presets, id: \.self) { percent in
            Toggle((Double(percent) / 100).formatted(.percent),
                   isOn: choice(pdf.fit == nil && Int((pdf.scale * 100).rounded()) == percent) {
                pdf.setScale(CGFloat(percent) / 100)
            })
        }
    }

    /// Checked while in use; choosing it, checked or not, applies it.
    private func choice(_ inUse: Bool, apply: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { inUse }, set: { _ in apply() })
    }
}

/// The find bar's rules, shared with the web's (web/src/findsession.js and
/// workspace.js `showCount`, `pdfFindTimer`).
enum PDFFind {
    static let maxQuery = 256
    static let maxMatches = 5000
    /// So typing doesn't search every prefix.
    static let debounce: Duration = .milliseconds(200)

    static func normalize(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
    }
}
