import SwiftUI

/// The web's Settings dialog (web/src/settings.js) as a standard macOS
/// Settings window: a tab per area, each a grouped form. Its "Floating
/// panels", "Interface size" and theme have no counterpart: macOS draws its
/// own sidebar and toolbar, sizes its own text, and the app follows the
/// system's appearance (HIG, Dark Mode).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Editor", systemImage: "character.cursor.ibeam") { EditorSettings() }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("pdfPaper") private var pdfPaper = "white"
    @AppStorage("paneBarSize") private var paneBarSize = PaneSize.compact

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
                    Text("Dark paper inverts the rendered PDF for night reading")
                }
                Picker(selection: $paneBarSize) {
                    Text("Compact").tag(PaneSize.compact)
                    Text("Large").tag(PaneSize.large)
                } label: {
                    Text("Toolbar Size")
                    Text("The controls over the source and the PDF")
                }
            }
            Section("Compiling") {
                Toggle(isOn: $app.autoCompile) {
                    Text("Compile Automatically")
                    Text("Recompile shortly after you stop typing")
                }
                LabeledContent("TeX Distribution") {
                    Text(app.tex?.available == true ? texVersion : "Not found — compiling is off")
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralSettings {
    /// latexmk's banner ("Latexmk, John Collins, 9 March 2026. Version 4.88")
    /// as "latexmk 4.88"; anything else as the core reported it.
    fileprivate var texVersion: String {
        guard let version = app.tex?.version else { return "Found" }
        if let match = version.firstMatch(of: /Version ([0-9][0-9.a-z]*)/) { return "latexmk \(match.1)" }
        return version
    }
}

private struct EditorSettings: View {
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 13
    @AppStorage("showWordCount") private var showWordCount = true

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $font) {
                    Text("System Monospaced").tag("system")
                    Text("JetBrains Mono").tag("jetbrains")
                }
                Stepper(value: $fontSize, in: 10...28) {
                    LabeledContent("Font Size", value: "\(fontSize) pt")
                }
                Picker("Syntax Colors", selection: $palette) {
                    Text("One Dark").tag("onedark")
                    Text("Xcode").tag("xcode")
                }
            }
            Section("Status") {
                Toggle(isOn: $showWordCount) {
                    Text("Word Count")
                    Text("Show words and lines in the status bar")
                }
            }
        }
        .formStyle(.grouped)
    }
}
