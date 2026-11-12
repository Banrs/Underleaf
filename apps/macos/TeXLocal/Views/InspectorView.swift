import SwiftUI

struct InspectorView: View {
    let project: ProjectModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.files.flattened.filter { $0.kind == .tex }.map(\.path)
                let main = project.mainFile
                Picker("Main File", selection: Bindable(project).mainFile) {
                    ForEach(texFiles, id: \.self) { Text($0).tag(Optional($0)) }
                    if !texFiles.contains(where: { $0 == main }) { Text(main ?? "").tag(main) }
                }
                EnginePicker(project: project)
                Toggle(isOn: Bindable(project).shellEscape) {
                    Text("Shell Escape"); Text("Lets packages such as minted run programs. Only for projects you trust.")
                }
                Toggle(isOn: Bindable(project).stopOnFirstError) {
                    Text("Stop on First Error"); Text("Ends the build at its first error, rather than showing them all.")
                }
                Button("Clean Build Folder") { Task { await project.cleanBuildFolder() } }
            }
            .disabled(project.settings == nil)
            Section {
                Toggle(isOn: Bindable(project).livePreview) {
                    Text("Live Preview")
                    Text(app.canPreviewLive ? "Experimental. Updates the preview as you type, without compiling." : Self.livePreviewMissing)
                }
                .disabled(!project.canSwitchLivePreview)
                if !app.canPreviewLive {
                    SettingsLink { Text("Open Settings…") }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let livePreviewMissing: LocalizedStringKey = "Live Preview needs TeXpresso. Install it, or choose its folder in Settings."
}

struct EnginePicker: View {
    let project: ProjectModel?

    var body: some View {
        Picker("Engine", selection: project.map { Bindable($0).engine } ?? .constant(nil)) {
            ForEach(Engine.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        .disabled(project?.engine == nil)
    }
}
