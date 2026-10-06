import AppKit
import SwiftUI

/// Native PDFKit pages, with controls in the toolbar, find accessory and status bar.
struct PDFPane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @AppStorage(PDFPrefs.paperKey) private var pdfPaper = PDFPrefs.paper
    @Environment(\.colorScheme) private var colorScheme

    private var darkPaper: Bool { pdfPaper == .dark || (pdfPaper == .auto && colorScheme == .dark) }

    var body: some View {
        if project.hasPDF {
            // Under the toolbar and the status bar, as the source; PDFKit insets its own scrolling.
            StatusBarGround(edges: [.top, .bottom, .trailing]) {
                PDFRepresentable(project: project, darkPaper: darkPaper)
            }
        } else {
            // The status bar's edge over this half too, as over the source's empty state.
            StatusBarGround { emptyState }
        }
    }

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

struct PDFFindBar: View {
    @Bindable var controller: PDFController

    var body: some View {
        FindBar(query: $controller.findText, prompt: "Find in PDF", field: controller.findField,
                matches: FindMatches(index: controller.matchIndex + 1, total: controller.matches.count,
                                     limited: controller.limited),
                searched: controller.query, step: controller.findNext, close: controller.closeFind)
            .task(id: controller.findText) {
                try? await Task.sleep(for: PDFFind.debounce)
                if !Task.isCancelled { controller.findTyped() }
            }
    }
}

/// Toolbar scale choices; no preset is checked between the listed scales.
struct ScaleMenuItems: View {
    let pdf: PDFController
    private static let presets = [50, 75, 100, 125, 150, 200]

    var body: some View {
        Toggle("Fit Width", isOn: choice(pdf.fit == .width) { pdf.fitWidth() })
        Toggle("Fit Page", isOn: choice(pdf.fit == .page) { pdf.fitPage() })
        Divider()
        ForEach(Self.presets, id: \.self) { percent in
            Toggle((Double(percent) / 100).formatted(.percent),
                   isOn: choice(pdf.fit == nil && Int((pdf.scale * 100).rounded()) == percent) {
                pdf.setScale(CGFloat(percent) / 100)
            })
        }
    }

    /// Choosing an already checked scale reapplies it.
    private func choice(_ inUse: Bool, apply: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { inUse }, set: { _ in apply() })
    }
}

enum PDFFind {
    static let maxQuery = 256
    static let maxMatches = 5000
    static let debounce: Duration = .milliseconds(200)

    static func normalize(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
    }

    /// The find text every app shares (the find pasteboard), which Use Selection for Find sets and
    /// a text view's find bar reads, so ⌘E in one pane and ⌘G in the other find the same.
    /// The tests' own, so they leave the user's alone.
    static var board = NSPasteboard(name: .find)

    static var shared: String? {
        get { board.string(forType: .string) }
        set {
            guard let newValue, !newValue.isEmpty, newValue != shared else { return }
            board.clearContents()
            board.setString(newValue, forType: .string)
        }
    }
}

enum PDFPaper: String, CaseIterable, Identifiable {
    case white, dark, auto

    var id: Self { self }

    var title: String {
        switch self {
        case .white: "White"
        case .dark: "Dark"
        case .auto: "Match Appearance"
        }
    }
}

enum PDFPrefs {
    static let paperKey = "pdfPaper"
    static let paper = PDFPaper.white
}
