import SwiftUI
import UIKit

/// The Mac's Settings panes as sections of one sheet, with Done (HIG, Sheets).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(DefaultsKey.newProjectEngine) private var engine = TeXEngine.pdflatex
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.overleaf
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true
    @AppStorage(DefaultsKey.syncAfterCompile) private var syncAfterCompile = false
    @AppStorage(DefaultsKey.pdfPaper) private var paper = PDFPaper.white

    private static let families = UIFont.familyNames.filter { family in
        UIFont.fontNames(forFamilyName: family).first.flatMap { UIFont(name: $0, size: 12) }?
            .fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
    }.sorted()

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Projects Folder", value: "On My iPad › TeXLocal")
                    // Files opens at the app's folder from this scheme.
                    Button("Show in Files") {
                        if let url = URL(string: "shareddocuments://" + Core.libraryFolder.path(percentEncoded: true)) { openURL(url) }
                    }
                } footer: {
                    Text("New and imported projects are kept here.")
                }
                Section("New Projects") {
                    Picker("Engine", detail: "Each project can change its engine in the inspector.", selection: $engine) {
                        ForEach(TeXEngine.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Text") {
                    Picker("Font", selection: $fontName) {
                        Text("System Monospaced").tag("")
                        ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Font Size: \(fontSize) pt", value: $fontSize, in: EditorPrefs.fontSizes)
                    Picker("Theme", detail: "Colours for commands, math and comments. All follow light and dark appearance.",
                           selection: $syntaxTheme) {
                        ForEach(SyntaxTheme.all) { Text($0.title).tag($0) }
                    }
                    Toggle("Show Line Numbers", isOn: $lineNumbers)
                }
                Section("Typing") {
                    Toggle("Close Brackets Automatically", detail: "Typing (, [ or { adds its partner.", isOn: $autoPair)
                    Toggle("Suggest Completions While Typing", isOn: $autoComplete)
                }
                Section("Compiling") {
                    Toggle("Compile Automatically", detail: "Compiles shortly after you stop typing.", isOn: $app.autoCompile)
                    Toggle("Scroll to Cursor After Compiling", detail: "Scrolls the PDF to the line you are editing.", isOn: $syncAfterCompile)
                }
                Section("PDF") {
                    Picker("Page Colour",
                           detail: "Dark inverts the PDF’s pages for reading at night, keeping their colours’ hues. Printing and saving are unaffected.",
                           selection: $paper) {
                        ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
