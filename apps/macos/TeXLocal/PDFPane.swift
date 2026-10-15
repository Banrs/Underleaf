import Accessibility
import AppKit
import SwiftUI

struct PDFPane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @AppStorage(PDFPrefs.paperKey) private var pdfPaper = PDFPrefs.paper
    @Environment(\.colorScheme) private var colorScheme

    private var darkPaper: Bool { pdfPaper == .dark || (pdfPaper == .auto && colorScheme == .dark) }

    var body: some View {
        if project.hasPDF {
            // Directly in the pane, not in another scroll view: PDFKit insets its own scrolling from the pane's safe area and rubber-bands
            // at its ends, which a scroll view around it takes over (27.2).
            PDFRepresentable(project: project, darkPaper: darkPaper)
                .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.textSurface)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !project.texAvailable {
            ContentUnavailableView {
                Label("MacTeX Isn’t Installed", systemImage: "richtext.page")
            } description: {
                Text("Install it to compile; TeXLocal finds it afterwards.")
            } actions: {
                GetMacTeXButton().buttonStyle(.borderedProminent)
            }
        } else if project.compiling {
            ContentUnavailableView("Compiling…", systemImage: "richtext.page")
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

struct PDFFindBar: View {
    @Bindable var controller: PDFController

    var body: some View {
        // For the query the matches are for, which the field can be ahead of.
        let label = PDFFind.count(controller.matchIndex + 1, of: controller.matches.count, limited: controller.limited, for: controller.query)
        HStack {
            SearchField(text: $controller.findText, prompt: "Find in PDF", handle: controller.findField,
                        step: controller.findNext, close: controller.closeFind)
                .frame(minWidth: 100, maxWidth: .infinity)
            ControlGroup {
                Button("Previous Match", systemImage: "chevron.backward") { controller.findNext(-1) }
                    .help("Go to the previous match")
                Button("Next Match", systemImage: "chevron.forward") { controller.findNext(1) }
                    .help("Go to the next match")
            }
            .disabled(controller.matches.isEmpty)
            .fixedSize()
            Text(label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .layoutPriority(-1)
            Button("Done") { controller.closeFind() }
        }
        .lineLimit(1)
        // VoiceOver's focus stays in the field, so it hears the count, or that there is none, from here, once it has settled:
        // the typing and stepping that change it cancel the wait.
        .task(id: label) {
            guard !label.isEmpty, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            var spoken = AttributedString(label)
            spoken.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(spoken).post()
        }
        .task(id: controller.findText) {
            try? await Task.sleep(for: PDFFind.debounce)
            if !Task.isCancelled { controller.findTyped() }
        }
    }
}

struct ScaleMenuItems: View {
    let pdf: PDFController

    var body: some View {
        Toggle("Fit Width", isOn: choice(pdf.fit == .width) { pdf.fitWidth() })
        Toggle("Fit Page", isOn: choice(pdf.fit == .page) { pdf.fitPage() })
        Divider()
        ForEach([50, 75, 100, 125, 150, 200], id: \.self) { percent in
            Toggle((Double(percent) / 100).formatted(.percent),
                   isOn: choice(pdf.fit == nil && Int((pdf.scale * 100).rounded()) == percent) {
                pdf.setScale(CGFloat(percent) / 100)
            })
        }
    }

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

    static func count(_ index: Int, of total: Int, limited: Bool, for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total.formatted())\(limited ? "+" : "")"
        return String(localized: "\(index) of \(count)")
    }

    /// The find text every app shares (the find pasteboard), so ⌘E in one pane and ⌘G in the other find the same;
    /// the tests' own leaves the user's alone.
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

#Preview("Find bar") {
    PDFFindBar(controller: PDFController())
        .frame(width: 480)
}
