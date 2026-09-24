import SwiftUI

/// The web's Settings dialog (web/src/settings.js) in the system's Settings
/// window. Its "Floating panels" has no counterpart: macOS draws its own
/// sidebar and toolbar.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("pdfPaper") private var pdfPaper = "white"
    @AppStorage("showWordCount") private var showWordCount = true
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 14
    @AppStorage("uiScale") private var uiScale = 100

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
                    Text("Auto").tag("auto")
                } label: {
                    Text("Document Paper")
                    Text("Dark paper inverts the rendered PDF for night reading")
                }
            }
            Section("Editor") {
                Toggle(isOn: $app.autoCompile) {
                    Text("Compile Automatically")
                    Text("Recompile shortly after you stop typing")
                }
                Toggle(isOn: $showWordCount) {
                    Text("Word Count")
                    Text("Show words and lines over the editor")
                }
                Picker("Syntax Colors", selection: $palette) {
                    Text("One Dark").tag("onedark")
                    Text("Xcode").tag("xcode")
                }
                Picker("Font", selection: $font) {
                    Text("System Monospaced").tag("system")
                    Text("JetBrains Mono").tag("jetbrains")
                }
                Stepper("Font Size: \(fontSize) pt", value: $fontSize, in: 10...28)
                Stepper {
                    Text("Interface Size: \(Double(uiScale) / 100, format: .percent)")
                    Text("Scales the editor; the sidebar and toolbar follow the system’s text size")
                } onIncrement: {
                    app.perform(.viewUIScaleUp)
                } onDecrement: {
                    app.perform(.viewUIScaleDown)
                }
            }
            Section("TeX") {
                LabeledContent("Distribution") {
                    Text(app.tex?.available == true
                         ? app.tex?.version ?? "TeX Live"
                         : "Not found — compilation disabled")
                }
                if let project = app.project {
                    Picker(selection: Binding(
                        get: { project.settings?.engine ?? "pdflatex" },
                        set: { engine in Task { await project.setEngine(engine) } }
                    )) {
                        ForEach(texEngines, id: \.0) { Text($0.1).tag($0.0) }
                    } label: {
                        Text("Engine")
                        Text(project.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onChange(of: appearance) { _, value in applyAppearance(value) }
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
