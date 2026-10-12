import SwiftUI

/// The inspector: the project's build settings. The file's word count and the last build
/// show in the status bar and the build panel, so it doesn't repeat them.
struct InspectorView: View {
    let project: ProjectModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.nodes.flattened.filter { !$0.isDirectory && isLaTeXFile($0.path) }.map(\.path)
                // The current value is always a choice, before the settings come (nil) or the
                // main file is in the file list: a selection with no tag is a SwiftUI fault.
                let main = project.settings?.mainFile
                Picker("Main File", selection: Binding(get: { main }, set: { new in
                    if let new { Task.immediate { await project.setMainFile(new) } }
                })) {
                    ForEach(texFiles, id: \.self) { Text($0).tag(Optional($0)) }
                    if !texFiles.contains(where: { $0 == main }) { Text(main ?? "").tag(main) }
                }
                EnginePicker(project: project)
                toggle("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.", "shellEscape",
                       project.settings?.shellEscape ?? false)
                toggle("Stop on First Error", "Ends the build at its first error, rather than showing them all.", "stopOnFirstError",
                       project.settings?.stopOnFirstError ?? false)
                Button("Clean Build Folder") { Task { await project.cleanBuildFolder() } }
            }
            // Settings arrive from the core after the project opens.
            .disabled(project.settings == nil)
            Section {
                // As Compile › Live Preview: on while this window's session is live.
                Toggle(isOn: Binding(get: { project.texpresso.active },
                                     set: { $0 ? project.startTeXpresso() : project.stopTeXpresso() })) {
                    Text("Live Preview")
                    Text(app.canPreviewLive ? "Experimental. Updates the preview as you type, without compiling."
                         : "Live Preview needs TeXpresso. Install it, or choose its folder in Settings.")
                }
                .disabled(!app.canPreviewLive || !project.initialLoadComplete || project.texpresso.phase == .stopping)
                if !app.canPreviewLive {
                    HStack {
                        Link("Get TeXpresso", destination: URL(string: "https://github.com/let-def/texpresso")!)
                        Spacer()
                        SettingsLink { Text("Open Settings…") }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ title: String, _ detail: String, _ key: String, _ isOn: Bool) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in Task.immediate { await project.setBuildOption([key: on]) } })) {
            Text(title)
            Text(detail)
        }
    }
}

/// The engine, in the inspector and the Compile menu: the current one is always a choice, as a
/// selection no tag matches is a SwiftUI fault. A menu with no choice marked before the settings come.
struct EnginePicker: View {
    let project: ProjectModel?

    var body: some View {
        if let project, let engine = project.settings?.engine {
            Picker("Engine", selection: Binding(get: { engine }, set: { new in Task.immediate { await project.setBuildOption(["engine": new]) } })) {
                ForEach(TeXEngine.allCases) { Text($0.title).tag($0.id) }
                if TeXEngine(rawValue: engine) == nil { Text(engine).tag(engine) }
            }
        } else {
            Menu("Engine") { ForEach(TeXEngine.allCases) { Text($0.title) } }
        }
    }
}
