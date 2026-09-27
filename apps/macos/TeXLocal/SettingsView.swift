import SwiftUI

/// The web's Settings dialog (web/src/settings.js) as a standard macOS
/// Settings window: a tab per area, each a grouped form. Its "Floating
/// panels", "Interface scale" and theme have no counterpart: macOS draws its
/// own sidebar and toolbar, sizes its own text, and the app follows the
/// system's appearance (HIG, Dark Mode).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings().settingsPane() }
            Tab("Editor", systemImage: "character.cursor.ibeam") { EditorSettings().settingsPane() }
        }
    }
}

extension View {
    /// A pane of the Settings window: a grouped form at its content's
    /// height, so the window fits each tab as it switches, as the system's
    /// own settings windows do. 500 pt wide, as the kit's example forms are.
    fileprivate func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("pdfPaper") private var pdfPaper = "white"
    @State private var choosingTeX = false
    @State private var alert: AppAlert?

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Appearance") {
                Picker(selection: $pdfPaper) {
                    Text("White").tag("white")
                    Text("Dark").tag("dark")
                    Text("Match Appearance").tag("auto")
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
                // One row: where TeX is (or Not Found, with Get MacTeX as
                // the start window has it), Choose… for a folder the
                // automatic search misses, and Use Automatic once one is
                // chosen. A spinner until the status is in, rather than "Not
                // Found" for a moment at launch.
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
        .fileImporter(isPresented: $choosingTeX, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { setTeXFolder(url.path) }
        }
        .fileDialogConfirmationLabel("Choose")
        .fileDialogMessage("Choose the folder latexmk is in, such as a TeX distribution’s bin folder.")
        // Here, not in the project window, whose alert the Settings window
        // may be covering.
        .alert($alert)
    }

    private func setTeXFolder(_ path: String?) {
        Task {
            do {
                try await app.setTeXFolder(path)
            } catch {
                alert = AppAlert("Couldn’t Use “\(((path ?? "") as NSString).lastPathComponent)”", error)
            }
        }
    }
}

private struct EditorSettings: View {
    @AppStorage(EditorPrefs.paletteKey) private var palette = EditorPrefs.palette
    @AppStorage(EditorPrefs.fontKey) private var font = EditorPrefs.font
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $font) {
                    Text("System Monospaced").tag("system")
                    Text("JetBrains Mono").tag("jetbrains")
                }
                // The system's stepper with its editable value, as a grouped
                // form lays it out: type a size or step to it, lined up with
                // the other rows' controls.
                Stepper("Font Size", value: size, in: Self.sizes, format: .number.precision(.fractionLength(0)))
                // "onedark" is the editor's own colours: One Dark in dark
                // mode and CodeMirror's default in light, so it isn't named
                // for one of them.
                Picker("Syntax Colors", selection: $palette) {
                    Text("Default").tag("onedark")
                    Text("Xcode").tag("xcode")
                }
            }
        }
    }

    private static let sizes: ClosedRange<Double> = 10...28

    /// A typed size, whole and kept within the sizes the stepper offers.
    /// Double, as the stepper's formatted value takes only floating point.
    private var size: Binding<Double> {
        Binding(get: { Double(fontSize) }, set: {
            fontSize = Int(min(max($0, Self.sizes.lowerBound), Self.sizes.upperBound).rounded())
        })
    }
}

#Preview("Editor") {
    EditorSettings().settingsPane()
}
