import AppKit
import SwiftUI

/// Sections of the Settings window's panes.
struct NewProjectSettings: View {
    @AppStorage(DefaultsKey.newProjectEngine) private var engine = TeXEngine.pdflatex

    var body: some View {
        Section("New Projects") {
            Picker("Engine", detail: "Each project can change its engine in the inspector.", selection: $engine) {
                ForEach(TeXEngine.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

struct EditorSettings: View {
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.system
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true
    private static let families = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .compactMap { NSFont(name: $0, size: 0)?.familyName }).sorted()
    private static let sizes = Double(EditorPrefs.fontSizes.lowerBound)...Double(EditorPrefs.fontSizes.upperBound)

    var body: some View {
        Section("Text") {
            Picker("Font", selection: $fontName) {
                Text("System Monospaced").tag("")
                Divider()
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                // A family since removed: a selection with no tag is a fault.
                if !fontName.isEmpty, !Self.families.contains(fontName) { Text(fontName).tag(fontName) }
            }
            Stepper("Font Size", value: size, in: Self.sizes, format: .number.precision(.fractionLength(0)))
            Picker("Theme", detail: "Colours for commands, math and comments. All follow light and dark appearance.",
                   selection: $syntaxTheme) {
                ForEach(SyntaxTheme.all) { Text($0.title).tag($0) }
            }
            Toggle("Show Line Numbers", isOn: $lineNumbers)
        }
        Section("Typing") {
            Toggle("Close Brackets Automatically", detail: "Typing (, [ or { adds its partner.", isOn: $autoPair)
            Toggle("Suggest Completions While Typing", detail: "When off, press Option-Escape to see suggestions.", isOn: $autoComplete)
        }
    }

    /// Double for the stepper's formatted value; clamped, as the range bounds its arrows and not a size typed in.
    private var size: Binding<Double> {
        Binding(get: { Double(fontSize) }, set: {
            fontSize = Int(min(max($0, Self.sizes.lowerBound), Self.sizes.upperBound).rounded())
        })
    }
}

struct CompilingToggles: View {
    @Environment(AppModel.self) private var app
    @AppStorage(DefaultsKey.syncAfterCompile) private var syncAfterCompile = false

    var body: some View {
        @Bindable var app = app
        Toggle("Compile Automatically", detail: "Compiles shortly after you stop typing.", isOn: $app.autoCompile)
        Toggle("Scroll to Cursor After Compiling", detail: "Scrolls the PDF to the line you are editing.", isOn: $syncAfterCompile)
    }
}

struct PaperPicker: View {
    @AppStorage(DefaultsKey.pdfPaper) private var paper = PDFPaper.white

    var body: some View {
        Picker("Page Colour",
               detail: "Dark inverts the PDF’s pages for reading at night, keeping their colours’ hues. Printing and saving are unaffected.",
               selection: $paper) {
            ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
        }
    }
}
