import SwiftUI

struct InspectorView: View {
    let project: ProjectModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.nodes.flattened.filter { $0.kind == .tex }.map(\.path)
                // The current value is always a choice, before the settings come (nil) or the main file is in the file list: a selection with no tag is a SwiftUI fault.
                let main = project.settings?.mainFile
                Picker("Main File", selection: Binding(get: { main }, set: { new in
                    if let new { Task.immediate { await project.patchSettings(.mainFile(new)) } }
                })) {
                    ForEach(texFiles, id: \.self) { Text($0).tag(Optional($0)) }
                    if !texFiles.contains(where: { $0 == main }) { Text(main ?? "").tag(main) }
                }
                EnginePicker(project: project)
                toggle("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.", SettingsChange.shellEscape,
                       project.settings?.shellEscape ?? false)
                toggle("Stop on First Error", "Ends the build at its first error, rather than showing them all.", SettingsChange.stopOnFirstError,
                       project.settings?.stopOnFirstError ?? false)
                Button("Clean Build Folder") { Task { await project.cleanBuildFolder() } }
            }
            .disabled(project.settings == nil)
            Section {
                Toggle("Live Preview", detail: app.canPreviewLive ? "Experimental. Updates the preview as you type, without compiling."
                           : "Live Preview needs TeXpresso. Install it, or choose its folder in Settings.",
                       isOn: Binding(get: { project.texpresso.active }, set: { $0 ? project.startTeXpresso() : project.stopTeXpresso() }))
                .disabled(!app.canPreviewLive || !project.initialLoadComplete || project.texpresso.phase == .stopping)
                if !app.canPreviewLive {
                    HStack {
                        OpenLinkButton.texpressoGuide
                        Spacer()
                        SettingsLink { Text("Open Settings…") }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ change: @escaping (Bool) -> SettingsChange,
                        _ isOn: Bool) -> some View {
        Toggle(title, detail: detail, isOn: Binding(get: { isOn }, set: { on in Task.immediate { await project.patchSettings(change(on)) } }))
    }
}

struct EnginePicker: View {
    let project: ProjectModel?

    var body: some View {
        let engine = project?.settings?.engine
        Picker("Engine", selection: Binding(get: { engine }, set: { new in
            if let project, let new { Task.immediate { await project.patchSettings(.engine(new)) } }
        })) {
            ForEach(TeXEngine.allCases) { Text($0.title).tag(Optional($0.id)) }
            if engine.flatMap(TeXEngine.init) == nil { Text(engine ?? "").tag(engine) }
        }
        .disabled(engine == nil)
    }
}
