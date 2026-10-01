import SwiftUI

/// One pane, titled "TeXLocal Settings" by the system: six controls need no tabs (HIG, Settings).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(EditorPrefs.paletteKey) private var palette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @AppStorage(PDFPrefs.paperKey) private var pdfPaper = PDFPrefs.paper
    @State private var choosingTeX = false
    @State private var alert: AppAlert?

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Editor") {
                Picker("Font", selection: $font) {
                    ForEach(EditorFont.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Font Size", value: size, in: Self.sizes, format: .number.precision(.fractionLength(0)))
                Picker("Syntax Colors", selection: $palette) {
                    ForEach(EditorPalette.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("PDF") {
                Picker(selection: $pdfPaper) {
                    ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Document Paper")
                    Text("Dark paper inverts the rendered PDF for night reading.")
                }
            }
            Section("Compiling") {
                Toggle(isOn: $app.autoCompile) {
                    Text("Compile Automatically")
                    Text("Recompile shortly after you stop typing.")
                }
                // A spinner until the status is in, rather than a flash of "Not Found" at launch.
                LabeledContent {
                    HStack {
                        if app.tex?.available == false { GetMacTeXButton() }
                        if app.tex?.texDir != nil { Button("Use Automatic") { setTeXFolder(nil) } }
                        Button("Choose…") { choosingTeX = true }
                    }
                } label: {
                    Text("TeX")
                    if let tex = app.tex {
                        if tex.available {
                            Text(tex.texDir ?? tex.found.map { "\($0), Automatic" } ?? "Automatic")
                        } else {
                            Text("Not Found")
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Looking for TeX")
                    }
                }
            }
        }
        // Sized to its content; 500 wide (UI kit example forms).
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $choosingTeX, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { setTeXFolder(url.path) }
        }
        .fileDialogConfirmationLabel("Choose")
        .fileDialogMessage("Choose the folder latexmk is in, such as a TeX distribution’s bin folder.")
        // Here, not in the project window, which Settings may cover.
        .alert($alert)
    }

    private func setTeXFolder(_ path: String?) {
        Task {
            do {
                try await app.setTeXFolder(path)
            } catch {
                alert = AppAlert(path.map { "Couldn’t Use “\(URL(filePath: $0).lastPathComponent)”" }
                                     ?? "Couldn’t Find TeX Automatically", error)
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
