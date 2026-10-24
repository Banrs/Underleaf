import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String { case general, editor, compiling, pdf, livePreview }

/// A Settings scene's TabView is its toolbar of panes, and titles and sizes the window to the pane (HIG, Settings).
struct SettingsView: View {
    @AppStorage(DefaultsKey.settingsPane) private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings().settingsPane() }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: .editor) { Form { EditorSettings() }.settingsPane() }
            Tab("Compiling", systemImage: "hammer", value: .compiling) { CompilingSettings().settingsPane() }
            Tab("PDF", systemImage: "richtext.page", value: .pdf) { Form { PaperPicker() }.settingsPane() }
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
            NewProjectSettings()
        }
    }
}

private struct CompilingSettings: View {
    var body: some View {
        Form {
            Section { CompilingToggles() }
            Section {
                ProgramFolder(program: .tex)
            } footer: {
                HelpLink(destination: Links.requirements).frame(maxWidth: .infinity, alignment: .trailing)
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
        // A spinner until the status is in, not a flash of "Not Found".
        if let tex = app.tex {
            let chosen = program == .tex ? tex.texDir : tex.texpressoDir
            LabeledContent {
                HStack {
                    if program.folder(in: tex) == nil {
                        if program == .tex {
                            Button("Install TinyTeX", action: install)
                                .buttonStyle(.borderedProminent)
                                .disabled(app.settingTeX)
                            LinkButton(title: "Get MacTeX", url: Links.mactex)
                        } else {
                            LinkButton(title: "Install Guide", url: Links.texpressoGuide)
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
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { setFolder(url.path) }
            }
            .fileDialogConfirmationLabel("Choose")
            .fileDialogMessage(program.dialogMessage)
            // TeX lives under folders the dialog hides (/usr/local, /opt, /Library/TeX).
            .fileDialogBrowserOptions(.includeHiddenFiles)
            .fileDialogDefaultDirectory(URL(filePath: program.folder(in: tex) ?? "/usr/local", directoryHint: .isDirectory))
            // Not in the project window, which Settings may cover.
            .alert($alert)
        } else {
            LabeledContent(program.title) { ProgressView().controlSize(.small).accessibilityLabel("Looking for \(program.title)") }
        }
    }

    private func install() {
        Task {
            do { try await app.installTeX() } catch { alert = AppAlert("Couldn’t Install TinyTeX", error) }
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
