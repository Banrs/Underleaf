import SwiftUI

/// The web's Settings dialog (web/src/settings.js) as a standard macOS
/// Settings window: a tab per area, each a grouped form. Its "Floating
/// panels" and "Interface size" have no counterpart: macOS draws its own
/// sidebar and toolbar, and sizes its own text.
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
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("pdfPaper") private var pdfPaper = "white"

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker(selection: $pdfPaper) {
                    Text("White").tag("white")
                    Text("Dark").tag("dark")
                    Text("Match Theme").tag("auto")
                } label: {
                    Text("Document Paper")
                    Text("Dark paper inverts the rendered PDF for night reading")
                }
            }
            Section("Compiling") {
                Toggle(isOn: $app.autoCompile) {
                    Text("Compile Automatically")
                    Text("Recompile shortly after you stop typing")
                }
                if let project = app.project {
                    Picker(selection: Binding(
                        get: { project.settings?.engine ?? "pdflatex" },
                        set: { engine in Task { await project.setEngine(engine) } }
                    )) {
                        ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
                    } label: {
                        Text("Engine")
                        Text("For \u{201C}\(project.id)\u{201D}")
                    }
                }
                LabeledContent("TeX Distribution") {
                    Text(app.tex?.available == true ? texVersion : "Not found — compiling is off")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, value in applyAppearance(value) }
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
    @AppStorage("editorFontSize") private var fontSize = 14
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
                    Text("Show words and lines over the editor")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "system" follows macOS; the others pin the app's appearance.
@MainActor
func applyAppearance(_ value: String) {
    NSApp.appearance = switch value {
    case "light": NSAppearance(named: .aqua)
    case "dark": NSAppearance(named: .darkAqua)
    default: nil
    }
}
