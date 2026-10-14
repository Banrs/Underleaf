import SwiftUI

enum SettingsPane: String {
    case general, editor, compiling, pdf, livePreview
}

/// The Settings window's panes. In a Settings scene a TabView is the window's toolbar of
/// panes, titles the window after the pane shown and sizes it to that pane (HIG, Settings).
struct SettingsView: View {
    /// The pane last shown, which the window opens on.
    @AppStorage(DefaultsKey.settingsPane) private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: .editor) { EditorSettings() }
            Tab("Compiling", systemImage: "hammer", value: .compiling) { CompilingSettings() }
            // The toolbar's PDF symbol and the status bar's Live Preview one.
            Tab("PDF", systemImage: "richtext.page", value: .pdf) { PDFSettings() }
            Tab("Live Preview", systemImage: "bolt", value: .livePreview) { LivePreviewSettings() }
        }
        // The UI kit's example forms' width.
        .frame(width: 500)
    }
}

extension View {
    /// A pane: a grouped form as tall as its rows.
    fileprivate func settingsPane() -> some View {
        formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(DefaultsKey.newProjectTemplate) private var template = ProjectTemplate.standard
    @AppStorage(DefaultsKey.newProjectEngine) private var engine = TeXEngine.pdflatex

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Core.libraryFolder]) }
                } label: {
                    Text("Projects Folder")
                    Text(Core.libraryPath)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("New and imported projects are kept here.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("New Projects") {
                Picker("Template", selection: $template) {
                    ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) }
                }
                Picker(selection: $engine) {
                    ForEach(TeXEngine.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Engine")
                    Text("Each project can change its engine in the inspector.")
                }
            }
        }
        .settingsPane()
    }
}

private struct EditorSettings: View {
    @AppStorage(EditorPrefs.fontNameKey) private var fontName = ""
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.fontSize
    @AppStorage(EditorPrefs.syntaxThemeKey) private var syntaxTheme = SyntaxTheme.overleaf
    @AppStorage(EditorPrefs.lineNumbersKey) private var lineNumbers = true
    @AppStorage(EditorPrefs.autoPairKey) private var autoPair = true
    @AppStorage(EditorPrefs.autoCompleteKey) private var autoComplete = true

    /// The installed fixed-pitch families, read once.
    private static let families = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .compactMap { NSFont(name: $0, size: 0)?.familyName }).sorted()
    private static let sizes = Double(EditorPrefs.fontSizes.lowerBound)...Double(EditorPrefs.fontSizes.upperBound)

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $fontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                    // A family since removed: a selection with no tag is a SwiftUI fault.
                    if !fontName.isEmpty, !Self.families.contains(fontName) { Text(fontName).tag(fontName) }
                }
                Stepper("Font Size", value: size, in: Self.sizes, format: .number.precision(.fractionLength(0)))
                Picker(selection: $syntaxTheme) {
                    ForEach(SyntaxTheme.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Theme")
                    Text("Colours for commands, math and comments. All follow light and dark appearance.")
                }
                Toggle("Show Line Numbers", isOn: $lineNumbers)
            }
            Section("Typing") {
                Toggle(isOn: $autoPair) {
                    Text("Close Brackets Automatically")
                    Text("Typing (, [ or { adds its partner.")
                }
                Toggle(isOn: $autoComplete) {
                    Text("Suggest Completions While Typing")
                    Text("When off, press Option-Escape to see suggestions.")
                }
            }
        }
        .settingsPane()
    }

    /// Double: the stepper's formatted value takes only floating point, and the editor reads a whole number.
    private var size: Binding<Double> {
        Binding(get: { Double(fontSize) }, set: {
            fontSize = Int(min(max($0, Self.sizes.lowerBound), Self.sizes.upperBound).rounded())
        })
    }
}

private struct CompilingSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(DefaultsKey.syncAfterCompile) private var syncAfterCompile = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle(isOn: $app.autoCompile) {
                    Text("Compile Automatically")
                    Text("Compiles shortly after you stop typing.")
                }
                Toggle(isOn: $syncAfterCompile) {
                    Text("Scroll to Cursor After Compiling")
                    Text("Scrolls the PDF to the line you are editing.")
                }
            }
            Section {
                ProgramFolder(program: .tex)
            } footer: {
                // One help button a window, in a pane's lower corner (HIG, Buttons).
                HelpLink(destination: URL(string: "https://github.com/Banrs/Underleaf#requirements")!)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .settingsPane()
    }
}

private struct PDFSettings: View {
    @AppStorage(PDFPrefs.paperKey) private var paper = PDFPrefs.paper

    var body: some View {
        Form {
            Picker(selection: $paper) {
                ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Page Colour")
                Text("Dark inverts the PDF’s pages for reading at night. Printing and saving are unaffected.")
            }
        }
        .settingsPane()
    }
}

private struct LivePreviewSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(LiveViewer.key) private var viewer = LiveViewer.pane

    var body: some View {
        Form {
            Section {
                if let tex = app.tex {
                    LabeledContent("TeXpresso") {
                        if tex.texpresso != nil {
                            Text("Installed")
                        } else {
                            Text("Not Installed")
                            TeXpressoGuideButton()
                        }
                    }
                }
                // An app opened from the Finder sees no shell PATH.
                ProgramFolder(program: .texpresso)
                Picker(selection: $viewer) {
                    ForEach(LiveViewer.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Show Live Preview In")
                    Text("Takes effect the next time Live Preview starts.")
                }
            } footer: {
                Text("Live Preview is experimental. It uses TeXpresso to update the PDF as you type, without compiling.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsPane()
    }
}

/// The folder a program runs from, picked as Safari picks its downloads folder: a pop-up of
/// Automatic, the folder chosen and Other…, with the folder in use underneath (HIG, Pop-up buttons).
/// Each row has its own file dialog and alert, so neither can act for the other program.
private struct ProgramFolder: View {
    enum Program {
        case tex, texpresso

        var title: String {
            switch self {
            case .tex: "TeX Distribution"
            case .texpresso: "TeXpresso Location"
            }
        }

        var dialogMessage: String {
            switch self {
            case .tex: "Choose the folder latexmk is in, such as a TeX distribution’s bin folder."
            case .texpresso: "Choose the folder the texpresso program is in."
            }
        }

        var automaticFailure: String {
            switch self {
            case .tex: "Couldn’t Find TeX Automatically"
            case .texpresso: "Couldn’t Find TeXpresso Automatically"
            }
        }

        /// The folder the user chose, if any.
        func chosen(in tex: TexStatus) -> String? {
            switch self {
            case .tex: tex.texDir
            case .texpresso: tex.texpressoDir
            }
        }

        /// The folder in use, if the program is found.
        func folder(in tex: TexStatus) -> String? {
            switch self {
            case .tex: tex.available ? tex.found ?? tex.texDir : nil
            case .texpresso: tex.texpresso.map { URL(filePath: $0).deletingLastPathComponent().path }
            }
        }

        /// "latexmk 4.87 in /Library/TeX/texbin", from latexmk's "Latexmk, John Collins, 17 Nov. 2025. Version 4.87";
        /// the folder alone when the line reads otherwise.
        func detail(in tex: TexStatus) -> String {
            guard let path = folder(in: tex) else { return "Not Found" }
            guard self == .tex, let number = tex.version?.firstMatch(of: /Version (\d[\w.]*)/)?.1 else { return path }
            return "latexmk \(number) in \(path)"
        }
    }
    let program: Program

    @Environment(AppModel.self) private var app
    @State private var choosing = false
    @State private var alert: AppAlert?

    private enum Choice: Hashable { case automatic, chosen, other }

    var body: some View {
        // A spinner until the status is in, rather than a flash of "Not Found" at launch.
        if let tex = app.tex {
            let chosen = program.chosen(in: tex)
            LabeledContent {
                HStack {
                    if program == .tex, !tex.available { GetMacTeXButton() }
                    if app.settingTeX { ProgressView().controlSize(.small).accessibilityLabel("Checking \(program.title)") }
                    Picker(program.title, selection: Binding<Choice>(get: { chosen == nil ? .automatic : .chosen }, set: {
                        switch $0 {
                        case .automatic: if chosen != nil { setFolder(nil) }
                        case .chosen: break
                        case .other: choosing = true
                        }
                    })) {
                        Text("Automatic").tag(Choice.automatic)
                        if let chosen {
                            Text(URL(filePath: chosen).lastPathComponent).tag(Choice.chosen)
                        }
                        Divider()
                        Text("Other…").tag(Choice.other)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(app.settingTeX)
                }
            } label: {
                Text(program.title)
                Text(program.detail(in: tex))
                    .textSelection(.enabled)
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { setFolder(url.path) }
            }
            .fileDialogConfirmationLabel("Choose")
            .fileDialogMessage(program.dialogMessage)
            // TeX lives under folders the dialog hides (/usr/local, /opt, /Library/TeX): open at the one in use, and show them.
            .fileDialogBrowserOptions(.includeHiddenFiles)
            .fileDialogDefaultDirectory(URL(filePath: program.folder(in: tex) ?? "/usr/local", directoryHint: .isDirectory))
            // Here, not in the project window, which Settings may cover.
            .alert($alert)
        } else {
            LabeledContent(program.title) { ProgressView().controlSize(.small).accessibilityLabel("Looking for \(program.title)") }
        }
    }

    private func setFolder(_ path: String?) {
        Task {
            do {
                try await app.setTeXFolder(path, texpresso: program == .texpresso)
            } catch {
                alert = AppAlert(path.map { "Couldn’t Use “\(URL(filePath: $0).lastPathComponent)”" } ?? program.automaticFailure, error)
            }
        }
    }
}
