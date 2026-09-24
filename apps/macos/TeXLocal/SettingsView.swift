import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 14

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section("Editor") {
                Picker("Syntax Colors", selection: $palette) {
                    Text("One Dark").tag("onedark")
                    Text("Xcode").tag("xcode")
                }
                Picker("Font", selection: $font) {
                    Text("System Monospaced").tag("system")
                    Text("JetBrains Mono").tag("jetbrains")
                }
                Stepper("Font Size: \(fontSize) pt", value: $fontSize, in: 10...28)
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
