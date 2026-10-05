import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @AppStorage(EditorPrefs.syntaxThemeKey) private var syntaxTheme = SyntaxTheme.overleaf
    @AppStorage(PDFPrefs.paperKey) private var pdfPaper = PDFPrefs.paper
    @AppStorage(LiveViewer.key) private var liveViewer = LiveViewer.pane
    /// The folder a file dialog is choosing: TeX's, or TeXpresso's.
    @State private var choosing: Program?
    enum Program { case tex, texpresso }
    @State private var alert: AppAlert?

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Editor") {
                Stepper("Font Size", value: size, in: Self.sizes, format: .number.precision(.fractionLength(0)))
                Picker("Colour Theme", selection: $syntaxTheme) {
                    ForEach(SyntaxTheme.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("PDF") {
                Picker(selection: $pdfPaper) {
                    ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Document Paper")
                    Text("Dark paper inverts the rendered PDF for night reading.")
                }
                // Three fixed choices, all in view (HIG, Toggles: radio buttons for two to five).
                .pickerStyle(.radioGroup)
            }
            Section("Compiling") {
                Toggle(isOn: $app.autoCompile) {
                    Text("Compile Automatically")
                    Text("Recompile shortly after you stop typing.")
                }
                // A spinner until the status is in, rather than a flash of "Not Found" at launch.
                if let tex = app.tex {
                    ProgramFolder(title: "TeX", inUse: tex.available ? tex.found ?? tex.texDir : nil,
                                  chosen: tex.texDir, busy: app.settingTeX) {
                        choosing = .tex
                    } automatic: { setTeXFolder(nil) } extra: {
                        if !tex.available { GetMacTeXButton() }
                    }
                    // Only Live Preview uses it, and an app opened from the Finder sees no shell PATH.
                    ProgramFolder(title: "TeXpresso (Experimental)",
                                  inUse: tex.texpresso.map { URL(filePath: $0).deletingLastPathComponent().path },
                                  chosen: tex.texpressoDir, busy: app.settingTeX) {
                        choosing = .texpresso
                    } automatic: { setTeXFolder(nil, texpresso: true) }
                    Picker(selection: $liveViewer) {
                        ForEach(LiveViewer.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Text("Live Preview In")
                        Text("TeXpresso’s own window draws with MuPDF. Takes effect when Live Preview next starts.")
                    }
                    .pickerStyle(.radioGroup)
                } else {
                    LabeledContent("TeX") { ProgressView().controlSize(.small).accessibilityLabel("Looking for TeX") }
                }
            }
        }
        // Sized to its content; 500 wide (UI kit example forms).
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        // One importer for both: a view's second would never present.
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                      allowedContentTypes: [.folder]) { [choosing] result in
            if case .success(let url) = result { setTeXFolder(url.path, texpresso: choosing == .texpresso) }
        }
        .fileDialogConfirmationLabel("Choose")
        .fileDialogMessage(choosing == .texpresso ? "Choose the folder the texpresso program is in."
                               : "Choose the folder latexmk is in, such as a TeX distribution’s bin folder.")
        // Here, not in the project window, which Settings may cover.
        .alert($alert)
    }

    private func setTeXFolder(_ path: String?, texpresso: Bool = false) {
        Task {
            do {
                try await app.setTeXFolder(path, texpresso: texpresso)
            } catch {
                alert = AppAlert(path.map { "Couldn’t Use “\(URL(filePath: $0).lastPathComponent)”" }
                                     ?? (texpresso ? "Couldn’t Find TeXpresso Automatically" : "Couldn’t Find TeX Automatically"), error)
            }
        }
    }

    private static let sizes: ClosedRange<Double> = 10...28

    /// Double: the stepper's formatted value takes only floating point.
    private var size: Binding<Double> {
        Binding(get: { Double(fontSize) }, set: {
            fontSize = Int(min(max($0, Self.sizes.lowerBound), Self.sizes.upperBound).rounded())
        })
    }
}

/// The folder a program runs from, picked as Safari picks its downloads folder: a pop-up of
/// Automatic, the folder chosen and Other…, with the folder in use underneath (HIG, Pop-up buttons).
private struct ProgramFolder<Extra: View>: View {
    let title: String
    /// Where the program was found; nil, Not Found.
    let inUse: String?
    let chosen: String?
    let busy: Bool
    let other: () -> Void
    let automatic: () -> Void
    @ViewBuilder var extra: () -> Extra

    private enum Choice: Hashable { case automatic, chosen, other }

    init(title: String, inUse: String?, chosen: String?, busy: Bool, other: @escaping () -> Void,
         automatic: @escaping () -> Void, @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        (self.title, self.inUse, self.chosen, self.busy) = (title, inUse, chosen, busy)
        (self.other, self.automatic, self.extra) = (other, automatic, extra)
    }

    var body: some View {
        LabeledContent {
            HStack {
                extra()
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Checking \(title)") }
                Picker(title, selection: Binding<Choice>(get: { chosen == nil ? .automatic : .chosen }, set: {
                    switch $0 {
                    case .automatic: if chosen != nil { automatic() }
                    case .chosen: break
                    case .other: other()
                    }
                })) {
                    Text("Automatic").tag(Choice.automatic)
                    if let chosen {
                        Text(URL(filePath: chosen).lastPathComponent).tag(Choice.chosen)
                    }
                    Divider()
                    Text("Other…").tag(Choice.other)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(busy)
            }
        } label: {
            Text(title)
            Text(inUse ?? "Not Found")
        }
    }
}
