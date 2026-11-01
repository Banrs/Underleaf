import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView(selection: Bindable(app).settingsPane) {
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

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
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
                Picker("Engine", detail: "Each project can change its engine in the inspector.", selection: $app.newProjectEngine) {
                    ForEach(Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

private struct EditorSettings: View {
    @Environment(AppModel.self) private var app
    private static let families = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .compactMap { NSFont(name: $0, size: 0)?.familyName }).sorted()
    private static let sizes = Double(AppModel.fontSizes.lowerBound)...Double(AppModel.fontSizes.upperBound)

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Text") {
                Picker("Font", selection: $app.fontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                    if !app.fontName.isEmpty, !Self.families.contains(app.fontName) { Text(app.fontName).tag(app.fontName) }
                }
                Stepper("Font Size", value: size, in: Self.sizes, format: .number.precision(.fractionLength(0)))
                Picker("Theme", detail: "Colours for commands, math and comments. All follow light and dark appearance.",
                       selection: $app.syntaxTheme) {
                    ForEach(SyntaxTheme.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Line Numbers", isOn: $app.lineNumbers)
            }
            Section("Typing") {
                Toggle("Close Brackets Automatically", detail: "Typing (, [ or { adds its partner.", isOn: $app.autoPair)
                Toggle("Suggest Completions While Typing", detail: "When off, press Option-Escape to see suggestions.", isOn: $app.autoComplete)
            }
        }
    }

    private var size: Binding<Double> {
        Binding(get: { Double(app.fontSize) }, set: {
            app.fontSize = Int(min(max($0, Self.sizes.lowerBound), Self.sizes.upperBound).rounded())
        })
    }
}

private struct CompilingSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle("Compile Automatically", detail: "Compiles shortly after you stop typing.", isOn: $app.autoCompile)
                Toggle("Scroll to Cursor After Compiling", detail: "Scrolls the PDF to the line you are editing.", isOn: $app.syncAfterCompile)
            }
            Section {
                ProgramFolder(program: .tex)
            }
        }
    }
}

private struct PDFSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Picker("Page Colour",
                   detail: "Dark inverts the PDF’s pages for reading at night, keeping their colours’ hues. Printing and saving are unaffected.",
                   selection: $app.paper) {
                ForEach(PDFPaper.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

private struct LivePreviewSettings: View {
    var body: some View {
        Form {
            Section {
                ProgramFolder(program: .texpresso)
            } footer: {
                Text("Live Preview is experimental. It uses TeXpresso to update the PDF as you type, without compiling.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

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
            if self == .texpresso, path == Core.helpersFolder.path { return "Built In" }
            guard self == .tex, let number = tex.latexmkVersion else { return path }
            return "latexmk \(number) in \(path)"
        }
    }
    let program: Program

    @Environment(AppModel.self) private var app
    @State private var choosing = false
    @State private var failure: String?

    private enum Choice: Hashable { case automatic, chosen, other }

    var body: some View {
        if let tex = app.tex {
            let chosen = program == .tex ? tex.texDir : tex.texpressoDir
            LabeledContent {
                HStack {
                    if program.folder(in: tex) == nil {
                        if program == .tex {
                            Button("Install TinyTeX") { attempt { try await app.installTeX() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(app.settingTeX)
                            Link("Get MacTeX", destination: Links.mactex)
                        } else {
                            Link("Install Guide", destination: Links.texpressoGuide)
                        }
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
                Text(app.installingTeX && program == .tex ? "Installing TinyTeX…" : program.detail(in: tex))
                    .textSelection(.enabled)
                if let failure { FailureText(text: failure) }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { setFolder(url.path) }
            }
            .fileDialogConfirmationLabel("Choose")
            .fileDialogMessage(program.dialogMessage)
            .fileDialogBrowserOptions(.includeHiddenFiles)
            .fileDialogDefaultDirectory(URL(filePath: program.folder(in: tex) ?? "/usr/local", directoryHint: .isDirectory))
        } else {
            LabeledContent(program.title) { ProgressView().controlSize(.small).accessibilityLabel("Looking for \(program.title)") }
        }
    }

    private func setFolder(_ path: String?) { attempt { try await app.setTeXFolder(path, texpresso: program == .texpresso) } }

    private func attempt(_ work: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do { try await work() } catch { failure = error.localizedDescription }
        }
    }
}
