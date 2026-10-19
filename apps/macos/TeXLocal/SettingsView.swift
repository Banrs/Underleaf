import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String { case general, editor, compiling, pdf, livePreview }

/// In a Settings scene a TabView is the window's toolbar of panes, titles the window after the pane shown and sizes it to that pane (HIG, Settings).
struct SettingsView: View {
    @AppStorage(DefaultsKey.settingsPane) private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings().settingsPane() }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: .editor) { EditorSettings().settingsPane() }
            Tab("Compiling", systemImage: "hammer", value: .compiling) { CompilingSettings().settingsPane() }
            Tab("PDF", systemImage: "richtext.page", value: .pdf) { PDFSettings().settingsPane() }
            Tab("Live Preview", systemImage: "bolt", value: .livePreview) { LivePreviewSettings().settingsPane() }
        }
        .frame(width: 500)
    }
}

extension View {
    fileprivate func settingsPane() -> some View {
        formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
    }
}

// A setting with a line under its title saying what it does, as Settings and the inspector show them.
extension Toggle where Label == TupleView<(Text, Text)> {
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title); Text(detail) }
    }
}

extension Picker where Label == TupleView<(Text, Text)> {
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title); Text(detail) }
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
                Text("New and imported projects are kept here.").frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("New Projects") {
                Picker("Template", selection: $template) { ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) } }
                Picker("Engine", detail: "Each project can change its engine in the inspector.", selection: $engine) {
                    ForEach(TeXEngine.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

private struct EditorSettings: View {
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.overleaf
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true

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
    }

    /// Double: the stepper's formatted value takes only floating point, and the editor reads a whole number.
    private var size: Binding<Double> {
        Binding(get: { Double(fontSize) }, set: { fontSize = Int($0.rounded()) })
    }
}

private struct CompilingSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(DefaultsKey.syncAfterCompile) private var syncAfterCompile = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle("Compile Automatically", detail: "Compiles shortly after you stop typing.", isOn: $app.autoCompile)
                Toggle("Scroll to Cursor After Compiling", detail: "Scrolls the PDF to the line you are editing.", isOn: $syncAfterCompile)
            }
            Section {
                ProgramFolder(program: .tex)
            } footer: {
                HelpLink(destination: Links.requirements).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct PDFSettings: View {
    @AppStorage(DefaultsKey.pdfPaper) private var paper = PDFPaper.white

    var body: some View {
        Form {
            Picker("Page Colour",
                   detail: "Dark inverts the PDF’s pages for reading at night, keeping their colours’ hues. Printing and saving are unaffected.",
                   selection: $paper) {
                ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

private struct LivePreviewSettings: View {
    @AppStorage(DefaultsKey.liveViewer) private var viewer = LiveViewer.pane

    var body: some View {
        Form {
            Section {
                // An app opened from the Finder sees no shell PATH.
                ProgramFolder(program: .texpresso)
                Picker("Show Live Preview In", detail: "Takes effect the next time Live Preview starts.", selection: $viewer) {
                    ForEach(LiveViewer.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Live Preview is experimental. It uses TeXpresso to update the PDF as you type, without compiling.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Each row has its own file dialog and alert, so neither can act for the other program.
private struct ProgramFolder: View {
    enum Program {
        case tex, texpresso

        var title: String { self == .tex ? "TeX Distribution" : "TeXpresso Location" }

        var dialogMessage: String {
            self == .tex ? "Choose the folder latexmk is in, such as a TeX distribution’s bin folder."
                : "Choose the folder the texpresso program is in."
        }

        func folder(in tex: TexStatus) -> String? {
            switch self {
            case .tex: tex.available ? tex.found ?? tex.texDir : nil
            case .texpresso: tex.texpresso.map { URL(filePath: $0).deletingLastPathComponent().path }
            }
        }

        func detail(in tex: TexStatus) -> String {
            guard let path = folder(in: tex) else { return "Not Found" }
            guard self == .tex, let number = tex.latexmkVersion else { return path }
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
            let chosen = program == .tex ? tex.texDir : tex.texpressoDir
            LabeledContent {
                HStack {
                    if program.folder(in: tex) == nil {
                        LinkButton(title: program == .tex ? "Get MacTeX" : "Install Guide", url: program == .tex ? Links.mactex : Links.texpressoGuide)
                    }
                    if app.settingTeX { ProgressView().controlSize(.small).accessibilityLabel("Checking \(program.title)") }
                    Picker(program.title, selection: Binding<Choice>(get: { chosen == nil ? .automatic : .chosen }, set: {
                        switch $0 {
                        case .automatic: if chosen != nil { setFolder(nil) }
                        case .chosen: break
                        case .other: choosing = true
                        }
                    })) {
                        Text("Automatic").tag(Choice.automatic)
                        if let chosen { Text(URL(filePath: chosen).lastPathComponent).tag(Choice.chosen) }
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
                alert = AppAlert(path.map { "Couldn’t Use “\(URL(filePath: $0).lastPathComponent)”" } ?? "Couldn’t Find \(program == .tex ? "TeX" : "TeXpresso") Automatically", error)
            }
        }
    }
}
