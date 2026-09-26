import SwiftUI

/// The web's Settings dialog (web/src/settings.js) as a standard macOS
/// Settings window: a tab per area, each a grouped form. Its "Floating
/// panels", "Interface size" and theme have no counterpart: macOS draws its
/// own sidebar and toolbar (View › Customize Toolbar… arranges it), sizes
/// its own text, and the app follows the system's appearance (HIG, Dark
/// Mode).
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
    /// own settings windows do.
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
                LabeledContent("TeX Distribution") {
                    Text(app.tex?.available == true ? texVersion : "Not found — compiling is off")
                }
            }
        }
    }

    /// The distribution ("TeX Live 2026"); else latexmk's banner
    /// ("Latexmk, John Collins, 9 March 2026. Version 4.88") as
    /// "latexmk 4.88"; anything else as the core reported it.
    private var texVersion: String {
        if let distribution = app.tex?.distribution { return distribution }
        guard let version = app.tex?.version else { return "Found" }
        if let match = version.firstMatch(of: /Version ([0-9][0-9.a-z]*)/) { return "latexmk \(match.1)" }
        return version
    }
}

private struct EditorSettings: View {
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 13

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
