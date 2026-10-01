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
                // The stepper next to its field (HIG, Steppers): a form's Stepper with a format
                // draws its arrows over its own field's end (27.2).
                LabeledContent("Font Size") {
                    HStack {
                        TextField("Font Size", value: size, format: .number)
                        Stepper("Font Size", value: size, in: Self.sizes)
                    }
                    .labelsHidden()
                }
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
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingTeX, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): setTeXFolder(url.path)
            case .failure(let error): alert = AppAlert("Couldn’t Choose the TeX Folder", error)
            }
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

    private static let sizes = 10...28

    /// A typed size is kept to the stepper's range.
    private var size: Binding<Int> {
        Binding(get: { fontSize }, set: { fontSize = min(max($0, Self.sizes.lowerBound), Self.sizes.upperBound) })
    }
}
